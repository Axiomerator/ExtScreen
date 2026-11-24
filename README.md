<p align="center"><img src="host/assets/extscreen-512.png" width="112" alt="ExtScreen 图标"></p>

<h1 align="center">ExtScreen</h1>

<p align="center">把安卓手机或平板用作 Windows 的低延迟扩展屏，支持触控、笔压与倾斜。</p>

<p align="center">
  <a href="https://github.com/Axiomerator/ExtScreen/releases">发布页</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

ExtScreen 基于 [Hrisit Roy](https://github.com/24f2006988) 的开源项目，于 2026 年 11 月 23 日更名并继续维护。

## 功能

- **Prism UI。** Windows 和安卓共享 Flutter + Prism UI 控件。安卓连接页适配手机和平板，串流中可通过液态玻璃浮层调整控制选项。两端都可在「设置 → 外观」中选择简体中文或 English、跟随系统、浅色或深色。首次启动默认跟随系统。

- **Windows 扩展显示。** Windows 会识别到一块独立的显示器，可以在系统设置里调整位置，并把窗口拖到平板上。驱动支持设备面板分辨率时可以逐像素显示。虚拟屏支持 60–144 Hz，实际可用模式取决于设备和驱动。
- **USB 有线和局域网。** 支持 USB 网络共享、Wi-Fi 和 ADB 直连。通过 USB 网络共享连接时，电脑会自动发现设备所在的链路，码率最高可达 120 Mbps。USB 网络共享和局域网可直接使用便携包。已通过 PIN 配对的设备会自动重连。
- **鼠标光标。** 在平板本地绘制 Windows 光标，静止画面上也能及时显示位置变化。触控和用笔时显示落点指示器，移动鼠标后恢复鼠标光标。`.ani` 动态皮肤在平板端显示首帧图形。
- **触控笔与多点触控。** 支持笔压曲线、倾斜、悬停、笔身按键映射为右键或橡皮擦，以及仅用笔模式、双指滚动和捏合缩放。
- **低延迟串流。** Windows 端使用 GPU 采集，优先使用硬件 HEVC 或 H.264 编码。安卓端硬件解码。串流支持自适应码率，笔下可显示本地预绘笔迹。
- **绘图快捷栏。** 可使用撤销、重做、修饰键和笔刷大小等快捷操作。

## 系统要求

| 设备或连接方式 | 要求 |
| --- | --- |
| Windows 电脑 | Windows 10 2004 或更新版本，或 Windows 11（x64）。Windows N 版需要启用 [Media Feature Pack](https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n)。建议使用支持硬件视频编码的 NVIDIA、AMD 或 Intel 显卡。 |
| 安卓设备 | Android 8.0 或更新版本，支持 `arm64-v8a`、`armeabi-v7a` 和 `x86_64`，串流支持横竖屏切换。触控笔可选。 |
| USB | 使用能传输数据的 USB 线。按设备支持情况选择 USB 网络共享或 ADB 直连。 |
| Wi-Fi 或局域网 | 电脑与安卓设备在同一局域网内，Windows 将该网络设为「专用网络」。无线连接建议使用 5 GHz Wi-Fi。 |

## 快速开始

升级时先从系统托盘退出旧版，再把新的 Windows ZIP 完整解压到新目录。已安装且正常的 MttVDD 驱动会继续使用。

如发布页暂未提供所需发行包，可按[从源码构建](#从源码构建)操作。

1. 在 Windows 上，从[发布页](https://github.com/Axiomerator/ExtScreen/releases)下载 `ExtScreen-<version>-Windows-x64.zip`，完整解压后双击 `ExtScreen.exe`。包内已带 Flutter、Visual C++ 运行库和已签名的 MttVDD 驱动。控制面板会自动启动主机并显示 6 位配对 PIN，也可通过系统托盘图标重新打开。
2. 若概览提示虚拟显示驱动未安装，点击 **安装驱动**，并在 Windows 提示中确认管理员权限。也可在 **设置 → 虚拟显示驱动** 安装或卸载驱动。驱动就绪后，下一次连接会尝试将平板作为扩展屏使用。
3. 下载并在安卓设备上安装 `ExtScreen-<version>.apk`。如果系统提示，允许当前安装来源。由早期调试或验收版改装正式发行版时，Android 要求先卸载签名不同的旧包。卸载会清除旧版设置和配对。
4. 按所用方式连接。
   - **USB 网络共享（推荐给支持该功能的设备）**。插上数据线，在安卓端点击 **开启 USB 网络共享**，开启系统设置中的 USB 网络共享，再回到 ExtScreen。在 **USB** 分区中选中电脑，首次连接输入控制面板上的 PIN。以后插线并开启共享时，已配对设备可以自动连接。
   - **Wi-Fi 或局域网**。在安卓端的 **局域网** 中选中电脑，或手动输入电脑的 IPv4 地址。首次连接时输入 PIN。
   - **直接 USB**。使用 USB 调试直连时，电脑需有 [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools)。在安卓端启用 USB 调试并授权这台电脑，再选择 **USB 直连**。也可使用 Android Open Accessory（AOA），按需运行 `support\ExtScreen-USB-Setup.cmd` 绑定 Windows 自带的 WinUSB 驱动。首次连接时在 Windows 控制面板确认。

连接后，可在 Windows **设置 → 系统 → 显示** 拖动新显示器图块，调整平板与其他屏幕的相对位置。

### 使用方式

- 点击安卓串流画面右上方的 **控制** 可调整帧率上限、码率、触控模式、笔压曲线、笔身按键和快捷栏。控制以半透明浮窗显示。子菜单收起后，浮窗外可继续操作画面。码率可先用 **自动**。
- 双指捏合可缩放画面。双指双击可重置缩放。
- 连续执行两次安卓返回操作，可回到连接界面。
- 同一时间串流到一台设备。另一台设备接管时，原设备会收到提示。

## 常见问题

| 现象 | 处理方法 |
| --- | --- |
| 已开启 USB 网络共享，安卓端找不到电脑 | 确认 Windows 主机程序正在运行。运行 `support\ExtScreen-USB-Tethering-Setup.cmd` 并确认管理员授权。该脚本会为有线 USB 子网配置防火墙规则。 |
| 开启 USB 网络共享后，电脑上网中断 | 运行 `support\ExtScreen-USB-Tethering-Setup.cmd`。它会让原有 Wi-Fi 或以太网的路由优先级高于 USB 网络共享。 |
| Wi-Fi 列表找不到电脑 | 确认两台设备位于同一局域网，并在 Windows 网络设置中选择「专用网络」。也可以在安卓端手动填写电脑的 IPv4 地址。 |
| Windows 没有出现第二块显示器 | 在控制面板查看虚拟显示驱动状态。安装完成后重新连接安卓设备。如仍未扩展，检查 Windows 显示设置中的新屏幕和控制面板的串流模式。 |
| PIN 错误或找不到 PIN | 打开 Windows 控制面板，在 **概览 → 设备配对** 点击 **更新 PIN**。 |
| Wi-Fi 画面模糊或卡顿 | 将码率设为 **自动**，靠近路由器并优先使用 5 GHz Wi-Fi，或使用有线 USB。 |
| 冷启动后平板上看不到鼠标光标 | 更新 Windows 主机和安卓 APK 后重新连接。触控后移动鼠标即可恢复光标。 |
| 窗口落在看不见的显示器上 | 按 `Win + P`，选择「仅电脑屏幕」。也可以启动 ExtScreen 后从托盘菜单退出，让它卸下虚拟显示器。 |
| 安装 APK 时提示与现有软件包冲突 | 检查 APK 是否与现有安装使用同一签名。更换签名时需先卸载旧版，卸载会清除应用数据及配对信息。 |

主机日志位于 `%LOCALAPPDATA%\ExtScreen\logs`。[报告问题时附上相关日志](https://github.com/Axiomerator/ExtScreen/issues)。

## 连接安全

USB 网络共享和局域网连接通过 SPAKE2 完成密码认证密钥交换。首次配对使用 6 位一次性 PIN，重连使用为该设备保存的 32 字节密钥。认证后，每个包均通过 ChaCha20-Poly1305 加密并认证。

连续输错五次 PIN 会暂停新设备配对并生成新的 PIN。Windows 防火墙规则按 `extscreen-host.exe` 和本地子网限定。普通无线连接使用专用网络的规则。

## 从源码构建

在 Windows 准备 [Rust](https://rustup.rs) 的 MSVC 工具链、Visual Studio 的 C++ 桌面开发工作负载、[FVM](https://fvm.app/)、JDK 17、Android SDK 36 和 NDK。

Flutter 版本由 [ui/.fvmrc](ui/.fvmrc) 固定为 3.50.0。把 `fvm` 加入 `PATH`。FVM 在其他目录时也可通过 `EXTSCREEN_FVM_EXE` 指向其可执行文件。设置 `ANDROID_HOME` 指向 Android SDK，按需通过 `ANDROID_NDK_HOME` 选择 NDK，通过 `EXTSCREEN_JAVA_HOME` 指定项目使用的 JDK 17。安装 Cargo Android 工具后，在仓库根目录执行发布脚本。

```powershell
cargo install cargo-ndk --locked
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
.\scripts\build_release.ps1
```

发布脚本运行测试，在 `dist\` 中生成 Android APK、Windows 便携 ZIP 和 `SHA256SUMS.txt`。需要单独生成本机验收包时，可传入 `-OutputDirectory .\dist\validation`。分步开发时，三个构建命令可分别执行。

```powershell
cargo build --release --locked --bin extscreen-host
.\scripts\build_windows_ui.ps1
.\scripts\build_android.ps1
```

Windows 控制面板在 `ui\build\windows\x64\runner\Release\`，该目录包含启动所需的 Flutter 文件。安卓调试 APK 位于 `client\app\build\outputs\apk\debug\app-debug.apk`。

发布版 APK 从 `EXTSCREEN_KEYSTORE_PROPERTIES` 指向的属性文件，或 `client\keystore.properties`，读取 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。缺少签名配置时，发布脚本生成未签名的 APK。直接在设备上试用时可构建调试签名的 APK。签名密钥由维护者在仓库外保管。

源码开发时，可用 `setup.bat` 安装驱动并配置 USB 网络共享和防火墙。通过 `run_extscreen.bat` 或 `run_extscreen_wifi.bat` 启动主机和控制面板。仅调试主机时可运行 `cargo run -p extscreen-host -- --minimized` 查看控制台日志。

在仓库根目录运行 `cargo test --workspace`，在 `client\native` 运行 `cargo test`，分别验证主机和安卓原生客户端。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `host/` | Rust Windows 主机，负责采集、编码、传输、输入注入和系统托盘 |
| `ui/` | Windows 控制面板、安卓连接页和串流浮层，共用 Flutter + Prism UI |
| `common/` | 两端共享的协议、输入格式和配对加密逻辑 |
| `client/app/` | Kotlin 安卓宿主，负责系统连接、视频显示和输入采样 |
| `client/native/` | Rust 安卓原生引擎，负责网络和硬件解码 |
| `driver/` | [虚拟显示驱动的显示模式和配置脚本](driver/README.md) |
| `installer/` | 可选安装器源码及随 Windows 包分发的驱动 |
| `scripts/` | 构建、安装与排查脚本 |

数据流、输入回传和连接方式见[架构说明](ARCHITECTURE.md)。各设备的排版、控件与导航规则见[界面设计](DESIGN.md)。组件示例、原生边界和开发验收见 [Prism UI 跨平台开发指南](docs/PRISM_UI_DEVELOPMENT.md)。

## 许可证

ExtScreen 按 [GNU 通用公共许可证第 3 版（GPL-3.0）](LICENSE)或你选择的后续版本授权。你可以使用、研究、修改和分享软件。分发修改版时请遵守所选许可证的条款。

随项目分发的第三方组件及其许可证见[第三方软件声明](THIRD_PARTY_NOTICES.md)。
