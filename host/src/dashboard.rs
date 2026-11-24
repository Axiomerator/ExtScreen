//! Local control plane for the Windows dashboard. Video and input use the existing transport.
use std::ffi::c_void;
use std::io;
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use extscreen_common::protocol::VideoCodec;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::Notify;
use tokio::time::timeout;
use tracing::warn;
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, HLOCAL};
use windows::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows::Win32::Security::{
    GetTokenInformation, TokenUser, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
    TOKEN_USER,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use crate::shared::{HostShared, LinkKind};
use crate::transport::{lan_addresses, pairing::USB_APPROVAL_TIMEOUT, usb_tether_addresses};

const PIPE_PATH: &str = r"\\.\pipe\ExtScreenHostDashboard.v1";
const MAX_REQUEST_BYTES: u64 = 4096;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
struct PendingApproval {
    id: u64,
    device_name: String,
    deadline: Instant,
    decision: mpsc::Sender<bool>,
}

static USB_APPROVAL: Mutex<Option<PendingApproval>> = Mutex::new(None);

/// PairingStore serializes USB consent requests and accepts only an explicit Allow.
pub fn request_usb_approval(device_name: &str, running: &AtomicBool) -> bool {
    let Ok(bytes) = extscreen_common::random_bytes::<8>() else {
        return false;
    };
    let id = u64::from_le_bytes(bytes) & (i64::MAX as u64);
    let deadline = Instant::now() + USB_APPROVAL_TIMEOUT;
    let (decision, answer) = mpsc::channel();
    {
        let mut slot = USB_APPROVAL.lock().unwrap_or_else(|err| err.into_inner());
        if !running.load(Ordering::Acquire) {
            return false;
        }
        *slot = Some(PendingApproval {
            id,
            device_name: device_name.to_owned(),
            deadline,
            decision,
        });
    }

    crate::shared::attach_to_default_desktop();
    let mut was_shown = crate::gui::dashboard_visible();
    crate::gui::show_dashboard();
    let allowed = loop {
        let now = Instant::now();
        let visible = crate::gui::dashboard_visible();
        if now >= deadline || (was_shown && !visible) {
            break false;
        }
        was_shown |= visible;
        match answer.recv_timeout((deadline - now).min(Duration::from_millis(200))) {
            Ok(allowed) => break allowed,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break false,
        }
    };

    let mut slot = USB_APPROVAL.lock().unwrap_or_else(|err| err.into_inner());
    if slot.as_ref().is_some_and(|pending| pending.id == id) {
        slot.take();
    }
    allowed
}

pub fn cancel_usb_approval() {
    let pending = USB_APPROVAL
        .lock()
        .unwrap_or_else(|err| err.into_inner())
        .take();
    if let Some(pending) = pending {
        let _ = pending.decision.send(false);
    }
}

fn pending_usb_approval() -> Option<Value> {
    let slot = USB_APPROVAL.lock().unwrap_or_else(|err| err.into_inner());
    let pending = slot.as_ref()?;
    let remaining = pending.deadline.checked_duration_since(Instant::now())?;
    Some(json!({
        "id": pending.id,
        "device_name": pending.device_name,
        "remaining_seconds": remaining.as_secs().max(1),
    }))
}

fn resolve_usb_approval(id: u64, allow: bool) -> bool {
    let mut slot = USB_APPROVAL.lock().unwrap_or_else(|err| err.into_inner());
    let Some(pending) = slot.as_ref() else {
        return false;
    };
    if pending.id != id || pending.deadline <= Instant::now() {
        return false;
    }
    if allow && !crate::gui::dashboard_visible() {
        return false;
    }
    slot.take()
        .is_some_and(|pending| pending.decision.send(allow).is_ok())
}

#[derive(Deserialize)]
#[serde(tag = "command", content = "value", rename_all = "snake_case")]
enum Request {
    Status,
    SetFps(u32),
    SetBitrate(u32),
    AdbReverse,
    DisplaySettings,
    InstallDisplayDriver,
    UninstallDisplayDriver,
    RequestKeyframe,
    NewPin,
    ForgetTablets,
    SetLocale(String),
    ResolveUsbApproval { id: u64, allow: bool },
    Exit,
}

pub fn spawn(shared: Arc<HostShared>, shutdown: Arc<Notify>) -> Result<()> {
    let descriptor: Vec<u16> = format!("D:P(A;;GA;;;{})", current_user_sid()?)
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut listening = open_pipe(&descriptor, true)?;
    tokio::spawn(async move {
        loop {
            if let Err(err) = listening.connect().await {
                warn!("Dashboard pipe connect failed: {err}");
                break;
            }
            let next = match open_pipe(&descriptor, false) {
                Ok(next) => next,
                Err(err) => {
                    warn!("Could not create the next dashboard pipe: {err}");
                    serve(listening, shared, shutdown).await;
                    break;
                }
            };
            tokio::spawn(serve(listening, shared.clone(), shutdown.clone()));
            listening = next;
        }
    });
    Ok(())
}

fn open_pipe(descriptor: &[u16], first: bool) -> Result<NamedPipeServer> {
    // The Windows default pipe DACL also grants rights to Everyone. Provide the current user's
    // SID explicitly so only that user can read the pairing PIN and control this host.
    unsafe {
        let mut security = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(descriptor.as_ptr()),
            SDDL_REVISION_1,
            &mut security,
            None,
        )?;
        let mut attrs = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: security.0,
            bInheritHandle: false.into(),
        };
        let result = ServerOptions::new()
            .first_pipe_instance(first)
            .reject_remote_clients(true)
            .create_with_security_attributes_raw(
                PIPE_PATH,
                (&mut attrs as *mut SECURITY_ATTRIBUTES).cast(),
            );
        let _ = LocalFree(HLOCAL(security.0));
        Ok(result?)
    }
}

fn current_user_sid() -> Result<String> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token)?;
        let result: Result<String> = (|| {
            let mut bytes = 0;
            let _ = GetTokenInformation(token, TokenUser, None, 0, &mut bytes);
            anyhow::ensure!(bytes > 0, "could not obtain Windows token user size");
            let mut buffer = vec![0_usize; (bytes as usize).div_ceil(std::mem::size_of::<usize>())];
            GetTokenInformation(
                token,
                TokenUser,
                Some(buffer.as_mut_ptr().cast::<c_void>()),
                bytes,
                &mut bytes,
            )?;
            let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
            let mut sid = PWSTR::null();
            ConvertSidToStringSidW(user.User.Sid, &mut sid)?;
            let result = sid.to_string();
            let _ = LocalFree(HLOCAL(sid.0.cast()));
            Ok(result?)
        })();
        let _ = CloseHandle(token);
        result
    }
}

async fn serve(mut pipe: NamedPipeServer, shared: Arc<HostShared>, shutdown: Arc<Notify>) {
    let mut line = Vec::new();
    {
        let mut reader = BufReader::new((&mut pipe).take(MAX_REQUEST_BYTES));
        let read = reader.read_until(b'\n', &mut line);
        if !matches!(timeout(REQUEST_TIMEOUT, read).await, Ok(Ok(1..))) {
            return;
        }
    }
    let request = if line.last() == Some(&b'\n') {
        serde_json::from_slice::<Request>(&line).ok()
    } else {
        None
    };
    let should_exit = matches!(request, Some(Request::Exit));
    let response = match request {
        Some(request) => dispatch(request, &shared).await,
        None => failure("invalid_request"),
    };

    if let Err(err) = send_response(&mut pipe, response).await {
        warn!("Could not send dashboard response: {err}");
    }
    if should_exit {
        shutdown.notify_one();
    }
}

async fn send_response(pipe: &mut NamedPipeServer, response: Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(&response)?;
    bytes.push(b'\n');
    timeout(REQUEST_TIMEOUT, pipe.write_all(&bytes)).await??;
    // Hold the server handle until the client has read the response and closed its handle.
    // Disconnecting the server first can discard unread pipe data.
    let _ = timeout(REQUEST_TIMEOUT, pipe.read_u8()).await;
    Ok(())
}

async fn dispatch(request: Request, shared: &Arc<HostShared>) -> Value {
    match request {
        Request::Status => return json!({ "ok": true, "status": status(shared) }),
        Request::SetFps(fps @ (0 | 60 | 90 | 120)) => shared.choose_fps(fps),
        Request::SetBitrate(0) => shared.choose_auto_bitrate(),
        Request::SetBitrate(kbps @ (15000 | 25000 | 35000 | 50000)) => {
            shared.choose_bitrate_kbps(kbps)
        }
        Request::AdbReverse => {
            let port = shared.tcp_port.load(Ordering::Relaxed);
            // A stalled ADB subprocess must not delay the Tokio runtime's shutdown.
            let (finished, result) = tokio::sync::oneshot::channel();
            let worker = std::thread::Builder::new()
                .name("extscreen-dashboard-adb".into())
                .spawn(move || {
                    let _ = finished.send(crate::gui::run_adb_reverse(port));
                });
            if worker.is_err() || !result.await.unwrap_or(false) {
                return failure("adb_reverse_failed");
            }
        }
        Request::DisplaySettings => {
            if !crate::gui::open_display_settings() {
                return failure("display_settings_failed");
            }
        }
        Request::InstallDisplayDriver | Request::UninstallDisplayDriver => {
            let operation = match request {
                Request::InstallDisplayDriver => crate::driver_control::Operation::Install,
                _ => crate::driver_control::Operation::Uninstall,
            };
            if let Err(error) = crate::driver_control::start(operation, shared) {
                return failure(error);
            }
        }
        Request::RequestKeyframe => shared.request_idr.store(true, Ordering::SeqCst),
        Request::NewPin => shared.pairing.rotate_pin(),
        Request::ForgetTablets => {
            if shared.pairing.device_count() > 0 {
                shared.pairing.forget_all();
            }
        }
        Request::SetLocale(ref code) if code == "zh" || code == "en" => {
            if let Err(err) = crate::gui::set_locale(code) {
                warn!("Could not save dashboard language: {err}");
                return failure("settings_write_failed");
            }
        }
        Request::ResolveUsbApproval { id, allow } => {
            if !resolve_usb_approval(id, allow) {
                return failure("approval_expired");
            }
        }
        Request::Exit => {}
        _ => return failure("invalid_request"),
    }
    json!({ "ok": true })
}

fn failure(error: &'static str) -> Value {
    json!({ "ok": false, "error": error })
}

fn status(shared: &HostShared) -> Value {
    let connected = shared.client_connected.load(Ordering::Relaxed);
    let session = shared
        .session
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let display = *shared.display.lock().unwrap_or_else(|e| e.into_inner());
    let codec = *shared
        .active_codec
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let stream = shared.stream_state();
    let (usb, lan) = network_addresses();
    json!({
        "connected": connected,
        "display_driver": crate::driver_control::status(shared, connected),
        "device_name": session.as_ref().map(|session| session.device_name.as_str()),
        "link": session.as_ref().map(|session| match session.link {
            LinkKind::UsbCable => "usb",
            LinkKind::UsbTether => "usb_tether",
            LinkKind::Wifi => "wifi",
        }),
        "usb_links": shared.usb_links.load(Ordering::Relaxed),
        "usb_approval": pending_usb_approval(),
        "port": shared.tcp_port.load(Ordering::Relaxed),
        "width": stream.stream_width,
        "height": stream.stream_height,
        "left": display.left,
        "top": display.top,
        "refresh_hz": stream.refresh_hz,
        "fps": stream.target_fps,
        "manual_fps": shared.manual_fps(),
        "bitrate_kbps": stream.bitrate_kbps,
        "manual_bitrate_kbps": stream.manual_bitrate_kbps,
        "orientation": match stream.orientation {
            extscreen_common::protocol::DisplayOrientation::Portrait => "portrait",
            extscreen_common::protocol::DisplayOrientation::Landscape => "landscape",
        },
        "codec": match codec { VideoCodec::Hevc => "HEVC", VideoCodec::H264 => "H.264", VideoCodec::Av1 => "AV1" },
        "pin": shared.pairing.pin(),
        "pairing_paused_seconds": shared.pairing.pairing_paused().map(|left| left.as_secs().max(1)),
        "paired_devices": shared.pairing.device_names(),
        "usb_addresses": usb,
        "lan_addresses": lan,
    })
}

struct Addresses {
    updated: Instant,
    usb: Vec<Ipv4Addr>,
    lan: Vec<Ipv4Addr>,
}

fn network_addresses() -> (Vec<Ipv4Addr>, Vec<Ipv4Addr>) {
    static CACHE: Mutex<Option<Addresses>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(ref addresses) = *cache {
        if addresses.updated.elapsed() < Duration::from_secs(2) {
            return (addresses.usb.clone(), addresses.lan.clone());
        }
    }
    let usb = usb_tether_addresses();
    let lan: Vec<Ipv4Addr> = lan_addresses()
        .into_iter()
        .filter(|ip| !usb.contains(ip))
        .collect();
    *cache = Some(Addresses {
        updated: Instant::now(),
        usb: usb.clone(),
        lan: lan.clone(),
    });
    (usb, lan)
}
