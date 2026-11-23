use std::ffi::OsStr;
use std::io::{BufRead, BufReader};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, OnceLock};
use std::thread;
use std::time::Duration;
use tokio::sync::Notify;
use tracing::{info, warn};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    ShellExecuteW, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE,
    NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow, DispatchMessageW,
    FindWindowW, GetCursorPos, GetMessageW, InsertMenuW, IsIconic, IsWindowVisible, LoadIconW,
    PostMessageW, PostQuitMessage, RegisterClassW, RegisterWindowMessageW, SetForegroundWindow,
    TrackPopupMenu, TranslateMessage, HICON, IDI_APPLICATION, MF_BYPOSITION, MF_SEPARATOR,
    MF_STRING, MSG, SW_SHOWNORMAL, TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RIGHTBUTTON,
    WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP, WM_CLOSE, WM_COMMAND, WM_DESTROY, WM_ENDSESSION,
    WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WNDCLASSW,
};

use crate::shared::HostShared;

const CREATE_NO_WINDOW: u32 = 0x08000000;
const TRAY_CLASS: PCWSTR = w!("ExtScreenHostTray");
const DASHBOARD_CLASS: PCWSTR = w!("ExtScreenFlutterDashboard");
const WM_TRAYICON: u32 = WM_APP + 1;
const WM_SHOW_DASHBOARD: u32 = WM_APP + 2;
const WM_DASHBOARD_CLOSE: u32 = WM_APP + 101;
const WM_DASHBOARD_RESTORE: u32 = WM_APP + 102;
const ID_TRAY_DASHBOARD: usize = 1000;
const ID_TRAY_ADB_REVERSE: usize = 1001;
const ID_TRAY_EXIT: usize = 1002;

static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);
static TRAY: OnceLock<TrayState> = OnceLock::new();
static CHINESE: OnceLock<AtomicBool> = OnceLock::new();

struct TrayState {
    shared: Arc<HostShared>,
    shutdown: Arc<Notify>,
}

fn to_wide_null(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(Some(0)).collect()
}

fn language_path() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|root| {
        PathBuf::from(root)
            .join("ExtScreen")
            .join("dashboard-language")
    })
}

fn chinese_setting() -> &'static AtomicBool {
    CHINESE.get_or_init(|| {
        let chinese = language_path()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .map_or_else(
                || unsafe {
                    windows::Win32::Globalization::GetUserDefaultUILanguage() & 0x3ff == 4
                },
                |code| code.trim() == "zh",
            );
        AtomicBool::new(chinese)
    })
}

pub fn set_locale(code: &str) -> std::io::Result<()> {
    let setting = chinese_setting();
    if let Some(path) = language_path() {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(path, code)?;
    }
    setting.store(code == "zh", Ordering::Relaxed);
    Ok(())
}

fn chinese() -> bool {
    chinese_setting().load(Ordering::Relaxed)
}

pub fn open_display_settings() -> bool {
    unsafe {
        let result = ShellExecuteW(
            HWND::default(),
            w!("open"),
            w!("ms-settings:display"),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
        result.0 as isize > 32
    }
}

pub fn show_running_dashboard() {
    unsafe {
        if let Ok(hwnd) = FindWindowW(TRAY_CLASS, None) {
            let _ = PostMessageW(hwnd, WM_SHOW_DASHBOARD, WPARAM(0), LPARAM(0));
        }
    }
}

pub fn close_desktop() {
    unsafe {
        if let Ok(hwnd) = FindWindowW(DASHBOARD_CLASS, None) {
            let _ = PostMessageW(hwnd, WM_DASHBOARD_CLOSE, WPARAM(0), LPARAM(0));
        }
        if let Ok(hwnd) = FindWindowW(TRAY_CLASS, None) {
            let _ = Shell_NotifyIconW(NIM_DELETE, &tray_icon_data(hwnd));
            let _ = PostMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }
}

pub fn dashboard_visible() -> bool {
    unsafe {
        FindWindowW(DASHBOARD_CLASS, None)
            .is_ok_and(|hwnd| IsWindowVisible(hwnd).as_bool() && !IsIconic(hwnd).as_bool())
    }
}

pub fn show_dashboard() {
    unsafe {
        if let Ok(hwnd) = FindWindowW(DASHBOARD_CLASS, None) {
            let _ = PostMessageW(hwnd, WM_DASHBOARD_RESTORE, WPARAM(0), LPARAM(0));
            return;
        }
    }

    let executable = std::env::var_os("EXTSCREEN_DASHBOARD_PATH")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .map(|exe| exe.with_file_name("extscreen.exe"))
        });
    if let Some(executable) = executable {
        if let Err(err) = Command::new(&executable).spawn() {
            warn!(
                "Could not open ExtScreen dashboard at {}: {err}",
                executable.display()
            );
        }
    }
}

unsafe fn app_icon() -> HICON {
    let instance = GetModuleHandleW(None)
        .map(|module| HINSTANCE(module.0))
        .unwrap_or_default();
    LoadIconW(instance, PCWSTR(1_usize as *const u16))
        .or_else(|_| LoadIconW(None, IDI_APPLICATION))
        .unwrap_or_default()
}

unsafe fn tray_icon_data(hwnd: HWND) -> NOTIFYICONDATAW {
    let mut icon = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        uCallbackMessage: WM_TRAYICON,
        hIcon: app_icon(),
        ..Default::default()
    };
    let tip = to_wide_null("ExtScreen");
    icon.szTip[..tip.len()].copy_from_slice(&tip);
    icon
}

pub fn spawn_tray(shared: Arc<HostShared>, shutdown: Arc<Notify>, show_window: bool) {
    let _ = TRAY.set(TrayState { shared, shutdown });
    if let Err(err) = thread::Builder::new()
        .name("extscreen-tray".into())
        .spawn(move || {
            crate::shared::attach_to_default_desktop();
            unsafe {
                let instance = GetModuleHandleW(None)
                    .map(|module| HINSTANCE(module.0))
                    .unwrap_or_default();
                let wnd_class = WNDCLASSW {
                    lpfnWndProc: Some(tray_window_proc),
                    hInstance: instance,
                    lpszClassName: TRAY_CLASS,
                    ..Default::default()
                };
                let _ = RegisterClassW(&wnd_class);
                let hwnd = match CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    TRAY_CLASS,
                    w!("ExtScreen Host"),
                    WINDOW_STYLE(0),
                    0,
                    0,
                    0,
                    0,
                    None,
                    None,
                    instance,
                    None,
                ) {
                    Ok(hwnd) => hwnd,
                    Err(err) => {
                        warn!("Could not create ExtScreen tray window: {err}");
                        if show_window {
                            show_dashboard();
                        }
                        return;
                    }
                };
                TASKBAR_CREATED.store(
                    RegisterWindowMessageW(w!("TaskbarCreated")),
                    Ordering::Relaxed,
                );
                let _ = Shell_NotifyIconW(NIM_ADD, &tray_icon_data(hwnd));
                if show_window {
                    show_dashboard();
                }

                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        })
    {
        warn!("Could not start ExtScreen tray thread: {err}");
        if show_window {
            show_dashboard();
        }
    }
}

unsafe extern "system" fn tray_window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let taskbar_created = TASKBAR_CREATED.load(Ordering::Relaxed);
    if taskbar_created != 0 && msg == taskbar_created {
        let _ = Shell_NotifyIconW(NIM_ADD, &tray_icon_data(hwnd));
        return LRESULT(0);
    }
    match msg {
        WM_ENDSESSION => {
            // Windows can terminate the host before its normal shutdown finishes.
            if wparam.0 != 0 {
                if let Some(state) = TRAY.get() {
                    state.shared.is_running.store(false, Ordering::SeqCst);
                }
                crate::capture::virtual_display::detach();
            }
        }
        WM_SHOW_DASHBOARD => show_dashboard(),
        WM_TRAYICON => match (lparam.0 & 0xffff) as u32 {
            WM_LBUTTONUP => show_dashboard(),
            WM_RBUTTONUP => show_tray_menu(hwnd),
            _ => {}
        },
        WM_COMMAND => match wparam.0 & 0xffff {
            ID_TRAY_DASHBOARD => show_dashboard(),
            ID_TRAY_ADB_REVERSE => {
                if let Some(state) = TRAY.get() {
                    let port = state.shared.tcp_port.load(Ordering::Relaxed);
                    let _ = thread::spawn(move || run_adb_reverse(port));
                }
            }
            ID_TRAY_EXIT => {
                if let Some(state) = TRAY.get() {
                    state.shutdown.notify_one();
                }
            }
            _ => {}
        },
        WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
        }
        WM_DESTROY => {
            let _ = Shell_NotifyIconW(NIM_DELETE, &tray_icon_data(hwnd));
            PostQuitMessage(0);
        }
        _ => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    LRESULT(0)
}

unsafe fn show_tray_menu(hwnd: HWND) {
    let Ok(menu) = CreatePopupMenu() else {
        return;
    };
    let labels = if chinese() {
        ["打开控制面板", "配置 ADB 端口转发", "退出 ExtScreen"]
    } else {
        [
            "Open Dashboard",
            "Set Up ADB Port Forwarding",
            "Exit ExtScreen",
        ]
    };
    for (index, (id, label)) in [ID_TRAY_DASHBOARD, ID_TRAY_ADB_REVERSE, ID_TRAY_EXIT]
        .into_iter()
        .zip(labels)
        .enumerate()
    {
        if index == 2 {
            let _ = InsertMenuW(menu, 2, MF_BYPOSITION | MF_SEPARATOR, 0, PCWSTR::null());
        }
        let label = to_wide_null(label);
        let position = index as u32 + u32::from(index == 2);
        let _ = InsertMenuW(
            menu,
            position,
            MF_BYPOSITION | MF_STRING,
            id,
            PCWSTR(label.as_ptr()),
        );
    }

    let mut cursor = POINT::default();
    let _ = GetCursorPos(&mut cursor);
    let _ = SetForegroundWindow(hwnd);
    let _ = TrackPopupMenu(
        menu,
        TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON,
        cursor.x,
        cursor.y,
        0,
        hwnd,
        None,
    );
    let _ = PostMessageW(hwnd, WM_NULL, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(menu);
}

fn find_adb_executable() -> Option<std::path::PathBuf> {
    // 1. App-relative paths (portable / installed bundle)
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            for sub in [r"tools\adb.exe", r"platform-tools\adb.exe", "adb.exe"] {
                let candidate = exe_dir.join(sub);
                if candidate.exists() {
                    return Some(candidate);
                }
            }
        }
    }
    // 2. Android SDK standard locations
    if let Ok(local_app_data) = std::env::var("LOCALAPPDATA") {
        let sdk_adb =
            std::path::Path::new(&local_app_data).join(r"Android\Sdk\platform-tools\adb.exe");
        if sdk_adb.exists() {
            return Some(sdk_adb);
        }
        // 3. WinGet package directory (e.g. Google.PlatformTools)
        let winget_dir = std::path::Path::new(&local_app_data).join(r"Microsoft\WinGet\Packages");
        if winget_dir.exists() {
            if let Ok(entries) = std::fs::read_dir(&winget_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        let candidate = path.join(r"platform-tools\adb.exe");
                        if candidate.exists() {
                            return Some(candidate);
                        }
                    }
                }
            }
        }
    }
    if let Ok(android_home) = std::env::var("ANDROID_HOME") {
        let sdk_adb = std::path::Path::new(&android_home).join(r"platform-tools\adb.exe");
        if sdk_adb.exists() {
            return Some(sdk_adb);
        }
    }
    if let Ok(android_root) = std::env::var("ANDROID_SDK_ROOT") {
        let sdk_adb = std::path::Path::new(&android_root).join(r"platform-tools\adb.exe");
        if sdk_adb.exists() {
            return Some(sdk_adb);
        }
    }
    None
}

fn adb_command() -> Command {
    if let Some(path) = find_adb_executable() {
        Command::new(path)
    } else {
        Command::new("adb")
    }
}

/// Maps the tablet's `127.0.0.1:59100` to the port the host really listens on.
pub fn run_adb_reverse(host_port: u16) -> bool {
    match adb_command()
        .args(["reverse", "tcp:59100", &format!("tcp:{host_port}")])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    {
        Ok(out) if out.status.success() => {
            info!("ADB port forwarding verified: reverse tcp:59100 tcp:{host_port} OK");
            true
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            warn!("ADB reverse command returned non-zero: {}", stderr.trim());
            false
        }
        Err(e) => {
            warn!("Failed to execute 'adb reverse': {}", e);
            false
        }
    }
}

pub fn spawn_adb_watcher(shared: Arc<HostShared>) {
    thread::Builder::new()
        .name("extscreen-adb-device-tracker".into())
        .spawn(move || {
            // `adb track-devices` is an event stream maintained by the ADB server.  In
            // contrast to repeatedly spawning `adb devices`, it is idle while the USB
            // topology is unchanged and wakes this thread only for an attach/detach.
            info!("ADB device tracker started (event-driven)");
            let mut last_devices = Vec::new();
            // A restarted host loses the reverse mapping but sees no device-set change, so
            // map once up front instead of waiting for an attach event.
            run_adb_reverse(shared.tcp_port.load(Ordering::Relaxed));
            while shared.is_running.load(Ordering::Relaxed) {
                let mut command = adb_command();
                let Ok(mut child) = command
                    .arg("track-devices")
                    .creation_flags(CREATE_NO_WINDOW)
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                else {
                    // ADB is optional; retry infrequently if it is installed after the host.
                    thread::sleep(Duration::from_secs(10));
                    continue;
                };

                let Some(stdout) = child.stdout.take() else {
                    let _ = child.kill();
                    let _ = child.wait();
                    thread::sleep(Duration::from_secs(10));
                    continue;
                };
                let mut current = Vec::new();
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if line.is_empty() {
                        if !current.is_empty() && current != last_devices {
                            info!(
                                "Android device set changed: {:?}; configuring ADB reverse",
                                current
                            );
                            run_adb_reverse(shared.tcp_port.load(Ordering::Relaxed));
                        }
                        last_devices = std::mem::take(&mut current);
                    } else {
                        let parts: Vec<_> = line.split_whitespace().collect();
                        if parts.len() >= 2 && parts[1] == "device" {
                            current.push(parts[0].to_owned());
                        }
                    }
                }
                let _ = child.kill();
                let _ = child.wait();
                if shared.is_running.load(Ordering::Relaxed) {
                    // Only recover from an exited ADB server; this is not a device poll.
                    thread::sleep(Duration::from_secs(2));
                }
            }
            info!("ADB device tracker stopped");
        })
        .expect("Failed to spawn ADB device tracker thread");
}
