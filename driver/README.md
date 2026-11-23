# 虚拟显示驱动

ExtScreen 使用开源的 [Virtual Display Driver（MttVDD）](https://github.com/VirtualDrivers/Virtual-Display-Driver) 在 Windows 上创建独立的扩展显示器。项目附带按 MIT 授权、由 SignPath Foundation 签名的 x64 用户模式驱动包，源码中的驱动位于 `installer/redist/vdd/`，Windows 便携包中的驱动位于 `support/driver/vdd/`。

## 在 ExtScreen 中管理

打开便携包根目录中的 `ExtScreen.exe`，在「设置 → 虚拟显示驱动」查看状态。需要扩展桌面时，点击「安装驱动」并批准 Windows 的管理员权限提示。驱动缺失或暂不可用时，安卓端仍可连接并镜像主显示器。

卸载前请先断开安卓设备。在同一设置区选择「卸载驱动」，确认后批准管理员权限。卸载仅移除硬件 ID 为 `Root\MttVDD` 的设备，保留驱动包和已有模式配置。如果界面提示重启，请在重启 Windows 后重新连接。

安卓设备连接时，主机会启用虚拟屏。模式列表包含设备原生分辨率时会优先使用它，否则选择尺寸接近的模式。需要调整屏幕排列时，可在 Windows 的「设置 → 系统 → 屏幕」操作。设备断开后，主机会将虚拟屏从桌面布局中移除。

## 调整分辨率

默认的 `vdd_settings.xml` 涵盖手机、平板和折叠屏的常见横屏分辨率，提供 60、75、90、120 和 144 Hz 刷新率。首次安装时，若系统中尚无配置，ExtScreen 会将此文件复制到 Windows 系统盘的 `VirtualDisplayDriver` 目录，并在 `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver` 下设置 `VDDPATH`。已有目录配置和 XML 文件会继续使用。

如需增加分辨率，请在 `VDDPATH` 指向目录的 XML 中新增横屏 `<resolution>` 项，确保宽度大于或等于高度，再重启 Windows 加载配置。

## 命令行

便携包内的 `support\ExtScreen-Display-Driver-Setup.cmd` 可在界面无法打开时启动同一套驱动安装流程。开发者也可以在仓库根目录打开管理员 PowerShell，通过已构建的主机程序管理驱动。

```powershell
$hostExe = '.\target\release\extscreen-host.exe'
& $hostExe --install-bundled-display-driver
& $hostExe --query-display-driver
& $hostExe --uninstall-display-driver
```

安装和卸载命令返回 `0` 表示成功，返回 `3010` 表示需重启后完成变更。只读查询在找到 MttVDD 设备时返回 `0`。
