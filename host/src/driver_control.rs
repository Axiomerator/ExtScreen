//! Operations requested by the desktop UI. Only the short-lived setup process is elevated.
use std::os::windows::ffi::OsStrExt;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tracing::warn;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, ERROR_CANCELLED, WAIT_OBJECT_0};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
use windows::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject, INFINITE};
use windows::Win32::UI::Shell::{
    ShellExecuteExW, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS,
    SHELLEXECUTEINFOW,
};
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

use crate::driver_setup::{self, DriverState, EXIT_REBOOT, INSTALL_BUNDLED_ARG, UNINSTALL_ARG};
use crate::shared::HostShared;

#[derive(Clone, Copy)]
pub enum Operation {
    Install,
    Uninstall,
}

impl Operation {
    const fn name(self) -> &'static str {
        match self {
            Self::Install => "installing",
            Self::Uninstall => "uninstalling",
        }
    }

    const fn argument(self) -> &'static str {
        match self {
            Self::Install => INSTALL_BUNDLED_ARG,
            Self::Uninstall => UNINSTALL_ARG,
        }
    }

    const fn failure(self) -> &'static str {
        match self {
            Self::Install => "driver_install_failed",
            Self::Uninstall => "driver_uninstall_failed",
        }
    }
}

#[derive(Default)]
struct OperationState {
    current: Option<Operation>,
    error: Option<&'static str>,
    restart_required: bool,
}

static OPERATION: Mutex<OperationState> = Mutex::new(OperationState {
    current: None,
    error: None,
    restart_required: false,
});

pub fn status(shared: &HostShared, connected: bool) -> Value {
    let probe = driver_setup::probe().ok();
    let state = match probe.as_ref().map(|probe| probe.state) {
        Some(DriverState::Ready) => "ready",
        Some(DriverState::Missing) => "missing",
        Some(DriverState::Unavailable) => "unavailable",
        None => "unknown",
    };
    let operation = OPERATION.lock().unwrap_or_else(|err| err.into_inner());
    let stream_mode = if !connected {
        "idle"
    } else if shared.capture_is_extended.load(Ordering::Relaxed) {
        "extended"
    } else {
        "fallback"
    };
    json!({
        "state": state,
        "bundle_available": driver_setup::has_bundle(),
        "operation": operation.current.map(Operation::name),
        "error": operation.error,
        "restart_required": operation.restart_required || probe.is_some_and(|probe| probe.restart_required),
        "stream_mode": stream_mode,
    })
}

pub fn start(operation: Operation, shared: &Arc<HostShared>) -> Result<(), &'static str> {
    let mut state = OPERATION.lock().unwrap_or_else(|err| err.into_inner());
    if state.current.is_some() {
        return Err("driver_busy");
    }
    let permit = shared
        .display_use
        .clone()
        .try_acquire_owned()
        .map_err(|_| "disconnect_before_driver_change")?;
    let probe = driver_setup::probe().map_err(|error| {
        warn!("Could not query the MttVDD driver: {error}");
        "driver_status_unavailable"
    })?;
    if probe.restart_required || state.restart_required {
        return Err("driver_restart_required");
    }
    if matches!(
        (operation, probe.state),
        (Operation::Install, DriverState::Ready) | (Operation::Uninstall, DriverState::Missing)
    ) {
        state.error = None;
        return Ok(());
    }
    if matches!(operation, Operation::Install) && !driver_setup::has_bundle() {
        return Err("driver_bundle_missing");
    }
    state.current = Some(operation);
    state.error = None;
    if let Err(error) = std::thread::Builder::new()
        .name("extscreen-driver-setup".into())
        .spawn(move || {
            let _permit = permit;
            let result = run_elevated(operation);
            if matches!((&result, operation), (Ok(0), Operation::Install)) {
                crate::capture::virtual_display::detach();
            }
            let mut state = OPERATION.lock().unwrap_or_else(|err| err.into_inner());
            state.current = None;
            match result {
                Ok(0) => {}
                Ok(code) if code == EXIT_REBOOT as u32 => state.restart_required = true,
                Ok(code) => {
                    warn!("MttVDD {} process exited with {code}", operation.name());
                    state.error = Some(operation.failure());
                }
                Err(code) => state.error = Some(code),
            }
        })
    {
        warn!("Could not start display driver setup thread: {error}");
        state.current = None;
        return Err(operation.failure());
    }
    Ok(())
}

fn run_elevated(operation: Operation) -> Result<u32, &'static str> {
    let exe = std::env::current_exe().map_err(|error| {
        warn!("Could not locate the host for driver setup: {error}");
        operation.failure()
    })?;
    let executable: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    let args: Vec<u16> = operation.argument().encode_utf16().chain(Some(0)).collect();

    // ShellExecute can load COM shell extensions. The worker owns its STA, not the host UI.
    let mut launch = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC,
        hwnd: crate::gui::dashboard_window(),
        lpVerb: w!("runas"),
        lpFile: PCWSTR(executable.as_ptr()),
        lpParameters: PCWSTR(args.as_ptr()),
        nShow: SW_HIDE.0 as i32,
        ..Default::default()
    };
    unsafe {
        let initialized = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
        let result = ShellExecuteExW(&mut launch);
        if initialized {
            CoUninitialize();
        }
        if let Err(error) = result {
            if error.code() == ERROR_CANCELLED.to_hresult() {
                return Err("driver_elevation_cancelled");
            }
            warn!(
                "Could not request elevation for MttVDD {}: {error}",
                operation.name()
            );
            return Err(operation.failure());
        }
        if launch.hProcess.is_invalid() {
            return Err(operation.failure());
        }
        let finished = WaitForSingleObject(launch.hProcess, INFINITE) == WAIT_OBJECT_0;
        let mut code = 0;
        let read = GetExitCodeProcess(launch.hProcess, &mut code);
        let _ = CloseHandle(launch.hProcess);
        if !finished || read.is_err() {
            return Err(operation.failure());
        }
        Ok(code)
    }
}
