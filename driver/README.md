# 虚拟显示驱动

ExtScreen 使用开源的 [Virtual Display Driver（MttVDD）](https://github.com/VirtualDrivers/Virtual-Display-Driver)在 Windows 上创建独立的扩展显示器。项目附带按 MIT 授权并经 Microsoft 签名的 x64 驱动包，源码中的驱动位于 `installer/redist/vdd/`，Windows 便携包中的驱动位于 `driver/vdd/`。

| 文件 | 用途 |
| --- | --- |
| `vdd_settings.xml` | 声明横屏分辨率，涵盖常见手机、平板和折叠屏比例，并提供 60、75、90、120、144 Hz 的刷新率。驱动安装脚本将配置复制到 `C:\VirtualDisplayDriver`，通过 `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver` 的 `VDDPATH` 值指定目录。 |
| `enable_virtual_display.ps1` | 从源码运行时，用管理员权限安装或重启驱动，并应用分辨率配置。 |

已安装 MttVDD 的电脑可直接运行便携包根目录中的 `extscreen.exe`。第一次设置扩展副屏时，双击解压目录中的 `ExtScreen-Display-Driver-Setup.cmd`，在 Windows 提示时允许管理员权限。脚本使用包内已签名的驱动，提示重启时请重启电脑。

安卓设备连接时，主机会启用虚拟屏。模式列表包含设备原生分辨率时优先使用它，否则选择尺寸接近的模式。设备断开后，主机将虚拟屏从桌面布局中移除。

如需增加分辨率，在 XML 中新增横屏的 `<resolution>` 项，确保宽度大于或等于高度，再让驱动重新加载配置。

也可以在仓库根目录打开管理员 PowerShell，通过已构建的主机程序管理驱动。

```powershell
$hostExe = '.\target\release\extscreen-host.exe'
& $hostExe --install-display-driver '.\installer\redist\vdd\MttVDD.inf'
& $hostExe --query-display-driver
& $hostExe --uninstall-display-driver
```

安装命令返回 `0` 表示成功，返回 `3010` 表示需要重启后完成安装。查询命令在找到驱动设备时返回 `0`。
