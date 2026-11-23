//! Installs and removes the virtual display driver (MttVDD) without devcon or winget.
//!
//! The driver is root-enumerated, so Windows will not create its device by itself: a device
//! node with the `Root\MttVDD` hardware id has to be registered first, then the driver bound to
//! it. This is what `devcon install MttVDD.inf Root\MttVDD` does. The installer runs these
//! commands elevated; they need administrator rights.

use std::fs;
use std::io::{self, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use windows::core::{w, PCWSTR};
use windows::Win32::Devices::DeviceAndDriverInstallation::{
    CM_Get_DevNode_Status, DiUninstallDevice, SetupDiCallClassInstaller,
    SetupDiCreateDeviceInfoList, SetupDiCreateDeviceInfoW, SetupDiDestroyDeviceInfoList,
    SetupDiEnumDeviceInfo, SetupDiGetClassDevsW, SetupDiGetDeviceRegistryPropertyW,
    SetupDiSetDeviceRegistryPropertyW, UpdateDriverForPlugAndPlayDevicesW, CM_DEVNODE_STATUS_FLAGS,
    CM_PROB, CM_PROB_NEED_RESTART, CR_SUCCESS, DICD_GENERATE_ID, DIF_REGISTERDEVICE, DIF_REMOVE,
    DIGCF_PRESENT, DN_HAS_PROBLEM, DN_STARTED, GUID_DEVCLASS_DISPLAY, HDEVINFO, INSTALLFLAG_FORCE,
    SPDRP_HARDWAREID, SP_DEVINFO_DATA,
};
use windows::Win32::Foundation::{BOOL, ERROR_FILE_NOT_FOUND, ERROR_NO_MORE_ITEMS, HWND};
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegGetValueW, RegSetValueExW, HKEY, HKEY_LOCAL_MACHINE,
    KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ, RRF_RT_REG_SZ,
};
use windows::Win32::System::SystemInformation::GetWindowsDirectoryW;

/// Hardware id the MttVDD INF matches.
pub const HARDWARE_ID: &str = crate::capture::virtual_display::DEVICE_ID;
/// Installs the driver from the INF path that follows it.
pub const INSTALL_ARG: &str = "--install-display-driver";
/// Removes the driver's device node.
pub const UNINSTALL_ARG: &str = "--uninstall-display-driver";
/// Installs the bundled signed driver and its default display modes.
pub const INSTALL_BUNDLED_ARG: &str = "--install-bundled-display-driver";
/// Exits 0 when the driver's device exists, 1 when it does not.
pub const QUERY_ARG: &str = "--query-display-driver";

/// Process exit code that tells the installer a restart is needed (same as msiexec).
pub const EXIT_REBOOT: i32 = 3010;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// A device information set, destroyed on drop.
struct DevInfo(HDEVINFO);

impl Drop for DevInfo {
    fn drop(&mut self) {
        let _ = unsafe { SetupDiDestroyDeviceInfoList(self.0) };
    }
}

/// Every device (present or not) whose hardware ids include [`HARDWARE_ID`].
fn matching_devices(present_only: bool) -> windows::core::Result<(DevInfo, Vec<SP_DEVINFO_DATA>)> {
    let flags = if present_only {
        DIGCF_PRESENT
    } else {
        Default::default()
    };
    let set = DevInfo(unsafe {
        SetupDiGetClassDevsW(
            Some(&GUID_DEVCLASS_DISPLAY),
            PCWSTR::null(),
            HWND::default(),
            flags,
        )?
    });
    let mut found = Vec::new();
    for index in 0.. {
        let mut data = SP_DEVINFO_DATA {
            cbSize: std::mem::size_of::<SP_DEVINFO_DATA>() as u32,
            ..Default::default()
        };
        if let Err(error) = unsafe { SetupDiEnumDeviceInfo(set.0, index, &mut data) } {
            if error.code() == ERROR_NO_MORE_ITEMS.to_hresult() {
                break;
            }
            return Err(error);
        }
        if hardware_ids(&set, &data)
            .iter()
            .any(|id| id.eq_ignore_ascii_case(HARDWARE_ID))
        {
            found.push(data);
        }
    }
    Ok((set, found))
}

fn hardware_ids(set: &DevInfo, data: &SP_DEVINFO_DATA) -> Vec<String> {
    let mut buffer = vec![0u8; 2048];
    let mut needed = 0u32;
    let read = unsafe {
        SetupDiGetDeviceRegistryPropertyW(
            set.0,
            data,
            SPDRP_HARDWAREID,
            None,
            Some(&mut buffer),
            Some(&mut needed),
        )
    };
    if read.is_err() {
        return Vec::new();
    }
    let len = (needed as usize).min(buffer.len()) / 2;
    let units: Vec<u16> = buffer
        .as_chunks::<2>()
        .0
        .iter()
        .take(len)
        .map(|c| u16::from_le_bytes(*c))
        .collect();
    parse_multi_sz(&units)
}

/// Splits a REG_MULTI_SZ (NUL-separated, double-NUL-terminated) UTF-16 buffer.
fn parse_multi_sz(units: &[u16]) -> Vec<String> {
    units
        .split(|&u| u == 0)
        .filter(|s| !s.is_empty())
        .map(String::from_utf16_lossy)
        .collect()
}

/// True when the virtual display driver's device node exists.
pub fn is_installed() -> bool {
    matching_devices(true)
        .map(|(_, devices)| !devices.is_empty())
        .unwrap_or(false)
}

/// Registers the root device (once) and installs the driver from `inf` onto it.
/// Returns whether Windows asked for a restart.
pub fn install(inf: &Path) -> anyhow::Result<bool> {
    let inf = fs::canonicalize(inf).map_err(|e| anyhow::anyhow!("{}: {e}", inf.display()))?;
    // SetupAPI rejects the extended-length prefix that canonicalize adds.
    let inf_text = inf.to_string_lossy();
    let inf_text = if let Some(path) = inf_text.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{path}")
    } else {
        inf_text.trim_start_matches(r"\\?\").to_owned()
    };
    let (_, devices) = matching_devices(true)?;
    let created = if devices.is_empty() {
        Some(register_root_device()?)
    } else {
        None
    };
    let (hwid, inf_w) = (wide(HARDWARE_ID), wide(&inf_text));
    let mut reboot = BOOL(0);
    let result = unsafe {
        UpdateDriverForPlugAndPlayDevicesW(
            HWND::default(),
            PCWSTR(hwid.as_ptr()),
            PCWSTR(inf_w.as_ptr()),
            INSTALLFLAG_FORCE,
            Some(&mut reboot),
        )
    };
    if let Err(error) = result {
        // Leave existing devices alone if an update fails. Remove only a node we just created.
        if let Some((set, mut device)) = created {
            if let Err(rollback) =
                unsafe { SetupDiCallClassInstaller(DIF_REMOVE, set.0, Some(&mut device)) }
            {
                eprintln!("ExtScreen driver rollback: {rollback}");
            }
        }
        return Err(anyhow::anyhow!(
            "installing the driver from {inf_text} failed: {error}"
        ));
    }
    Ok(reboot.as_bool())
}

fn register_root_device() -> anyhow::Result<(DevInfo, SP_DEVINFO_DATA)> {
    let set = DevInfo(unsafe {
        SetupDiCreateDeviceInfoList(Some(&GUID_DEVCLASS_DISPLAY), HWND::default())?
    });
    let mut data = SP_DEVINFO_DATA {
        cbSize: std::mem::size_of::<SP_DEVINFO_DATA>() as u32,
        ..Default::default()
    };
    let class_name = wide("Display");
    unsafe {
        SetupDiCreateDeviceInfoW(
            set.0,
            PCWSTR(class_name.as_ptr()),
            &GUID_DEVCLASS_DISPLAY,
            PCWSTR::null(),
            HWND::default(),
            DICD_GENERATE_ID,
            Some(&mut data),
        )?;
        // REG_MULTI_SZ: the id, then an empty string.
        let ids: Vec<u8> = HARDWARE_ID
            .encode_utf16()
            .chain([0, 0])
            .flat_map(|u| u.to_le_bytes())
            .collect();
        SetupDiSetDeviceRegistryPropertyW(set.0, &mut data, SPDRP_HARDWAREID, Some(&ids))?;
        SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set.0, Some(&data))?;
    }
    Ok((set, data))
}

/// Removes every device node of the virtual display driver. Returns whether a restart is needed.
pub fn uninstall() -> anyhow::Result<bool> {
    let (set, devices) = matching_devices(false)?;
    let mut reboot_any = false;
    for data in &devices {
        let mut reboot = BOOL(0);
        unsafe { DiUninstallDevice(HWND::default(), set.0, data, 0, Some(&mut reboot))? };
        reboot_any |= reboot.as_bool();
    }
    Ok(reboot_any)
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum DriverState {
    Ready,
    Missing,
    Unavailable,
}

pub struct Probe {
    pub state: DriverState,
    pub restart_required: bool,
}

pub fn probe() -> windows::core::Result<Probe> {
    let (_, devices) = matching_devices(true)?;
    let mut ready = false;
    let mut restart_required = false;
    for device in &devices {
        let mut status = CM_DEVNODE_STATUS_FLAGS::default();
        let mut problem = CM_PROB::default();
        if unsafe { CM_Get_DevNode_Status(&mut status, &mut problem, device.DevInst, 0) }
            == CR_SUCCESS
        {
            ready |= status.0 & DN_STARTED.0 != 0 && status.0 & DN_HAS_PROBLEM.0 == 0;
            restart_required |= problem == CM_PROB_NEED_RESTART;
        }
    }
    let state = if ready {
        DriverState::Ready
    } else if devices.is_empty() {
        DriverState::Missing
    } else {
        DriverState::Unavailable
    };
    Ok(Probe {
        state,
        restart_required,
    })
}

struct DriverBundle {
    inf: PathBuf,
    settings: PathBuf,
}

fn driver_bundle() -> Option<DriverBundle> {
    let exe = std::env::current_exe().ok()?;
    let directory = exe.parent()?;
    let packaged = directory.join("driver");
    let bundled = DriverBundle {
        inf: packaged.join("vdd").join("MttVDD.inf"),
        settings: packaged.join("vdd_settings.xml"),
    };
    if bundled.inf.is_file() && bundled.settings.is_file() {
        return Some(bundled);
    }

    // Source builds place the host under the repository's target directory.
    for ancestor in directory.ancestors().take(4) {
        let bundled = DriverBundle {
            inf: ancestor
                .join("installer")
                .join("redist")
                .join("vdd")
                .join("MttVDD.inf"),
            settings: ancestor.join("driver").join("vdd_settings.xml"),
        };
        if bundled.inf.is_file() && bundled.settings.is_file() {
            return Some(bundled);
        }
    }
    None
}

pub fn has_bundle() -> bool {
    driver_bundle().is_some()
}

fn install_bundled() -> anyhow::Result<bool> {
    let probe = probe()?;
    if probe.state == DriverState::Ready || probe.restart_required {
        return Ok(probe.restart_required);
    }
    let bundle = driver_bundle()
        .ok_or_else(|| anyhow::anyhow!("bundled MttVDD driver files are missing"))?;
    install_default_display_modes(&bundle.settings)?;
    install(&bundle.inf)
}

const DRIVER_REGISTRY_KEY: PCWSTR = w!("SOFTWARE\\MikeTheTech\\VirtualDisplayDriver");
const DRIVER_PATH_VALUE: PCWSTR = w!("VDDPATH");

fn install_default_display_modes(settings: &Path) -> anyhow::Result<()> {
    let mut config_path = vec![0_u16; 32_768];
    let mut byte_len = (config_path.len() * std::mem::size_of::<u16>()) as u32;
    let registry_result = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            DRIVER_REGISTRY_KEY,
            DRIVER_PATH_VALUE,
            RRF_RT_REG_SZ,
            None,
            Some(config_path.as_mut_ptr().cast()),
            Some(&mut byte_len),
        )
    };
    let existing_path = registry_result.is_ok();
    if !existing_path && registry_result != ERROR_FILE_NOT_FOUND {
        registry_result.ok()?;
    }
    let config_dir = if existing_path {
        let path = String::from_utf16_lossy(&config_path[..(byte_len as usize / 2)]);
        let path = PathBuf::from(path.trim_end_matches('\0'));
        anyhow::ensure!(path.is_absolute(), "VDDPATH is not an absolute path");
        path
    } else {
        let count = unsafe { GetWindowsDirectoryW(Some(&mut config_path)) } as usize;
        anyhow::ensure!(
            count > 0 && count < config_path.len(),
            "could not find Windows directory"
        );
        let windows = PathBuf::from(String::from_utf16_lossy(&config_path[..count]));
        windows
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Windows directory has no parent"))?
            .join("VirtualDisplayDriver")
    };
    fs::create_dir_all(&config_dir)?;
    let settings_bytes = fs::read(settings)?;
    let destination = config_dir.join("vdd_settings.xml");
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&destination)
    {
        Ok(mut file) => {
            if let Err(error) = file.write_all(&settings_bytes) {
                drop(file);
                let _ = fs::remove_file(&destination);
                return Err(error.into());
            }
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    if !existing_path {
        let bytes: Vec<u8> = config_dir
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .flat_map(u16::to_le_bytes)
            .collect();
        let mut key = HKEY::default();
        unsafe {
            RegCreateKeyExW(
                HKEY_LOCAL_MACHINE,
                DRIVER_REGISTRY_KEY,
                0,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_SET_VALUE,
                None,
                &mut key,
                None,
            )
            .ok()?;
            let result = RegSetValueExW(key, DRIVER_PATH_VALUE, 0, REG_SZ, Some(&bytes));
            let _ = RegCloseKey(key);
            result.ok()?;
        }
    }
    Ok(())
}

/// Entry point for the command-line modes; returns the process exit code.
pub fn run_cli(mode: &str, arg: Option<String>) -> i32 {
    let result = match mode {
        INSTALL_ARG => match arg {
            Some(inf) => install(Path::new(&inf)),
            None => Err(anyhow::anyhow!("usage: {INSTALL_ARG} <path to MttVDD.inf>")),
        },
        INSTALL_BUNDLED_ARG => install_bundled(),
        UNINSTALL_ARG => uninstall(),
        QUERY_ARG => return if is_installed() { 0 } else { 1 },
        _ => return 2,
    };
    match result {
        Ok(true) => EXIT_REBOOT,
        Ok(false) => 0,
        Err(e) => {
            // The installer shows its own message; just report why on stderr.
            eprintln!("ExtScreen driver setup: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multi_sz_is_split_into_ids() {
        let units: Vec<u16> = "Root\\MttVDD\0MttVDD\0\0".encode_utf16().collect();
        assert_eq!(
            parse_multi_sz(&units),
            vec!["Root\\MttVDD".to_string(), "MttVDD".to_string()]
        );
    }

    #[test]
    fn empty_multi_sz_has_no_ids() {
        assert!(parse_multi_sz(&[0, 0]).is_empty());
    }
}
