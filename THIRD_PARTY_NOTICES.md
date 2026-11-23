# 第三方软件声明

ExtScreen 按 GNU GPL 第 3 版或后续版本授权，全文见 [LICENSE](LICENSE)。下列第三方组件各自适用相应许可证。

## 随 Windows 便携版与可选安装器分发

| 组件 | 用途 | 许可证 | 来源 |
| --- | --- | --- | --- |
| Virtual Display Driver（MttVDD）25.7.23，已签名的驱动包 | 在 Windows 上创建用于串流的扩展显示器 | [MIT](installer/redist/vdd/LICENSE.txt) | [Virtual Display Driver 项目](https://github.com/VirtualDrivers/Virtual-Display-Driver) |

Windows 便携 ZIP 中的驱动许可证位于 `driver/vdd/LICENSE.txt`。

| 组件 | 用途 | 许可证 |
| --- | --- | --- |
| [Flutter SDK](https://github.com/flutter/flutter) | Windows 和安卓界面引擎 | [BSD-3-Clause](https://github.com/flutter/flutter/blob/main/LICENSE) |
| [Prism UI 0.1.3](https://pub.dev/packages/prism_ui/versions/0.1.3) | 主题、控件与液态玻璃 | [GPL-3.0](https://pub.dev/packages/prism_ui/versions/0.1.3/license) |
| Microsoft Visual C++ 可再发行运行库 | 运行 Flutter Windows 控制面板 | [Microsoft Visual Studio 可再发行组件条款](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files) |

Flutter 构建产物中的 `flutter_assets/NOTICES.Z` 包含随包分发的 Dart 和 Flutter 依赖的许可证。

## 编译时引入

Windows 主机和安卓原生库使用 crates.io 上发布的 Rust crate。以下列出主要组件。完整依赖及其许可证可在仓库根目录和 `client/native` 分别运行 `cargo tree -e normal --format "{p} {l}"` 查看。

| Crate | 用途 | 许可证 |
| --- | --- | --- |
| `windows`、`windows-capture` | Win32 和 Windows Graphics Capture 绑定 | `windows` 为 MIT 或 Apache-2.0，`windows-capture` 为 MIT |
| `tokio` | 主机的异步网络通信 | MIT |
| `openh264`（包含 Cisco OpenH264 源码） | H.264 软件编码回退 | BSD-2-Clause |
| `rusb`、`libusb1-sys`（包含 libusb 源码） | Android Open Accessory 模式通信 | Rust crate 为 MIT，libusb 本身为 LGPL-2.1-or-later |
| `spake2`、`chacha20poly1305`、`sha2`、`hkdf` | 设备配对和加密 | MIT 或 Apache-2.0 |
| `jni`、`ndk`、`android_logger` | Android 平台集成 | MIT 或 Apache-2.0 |

安卓应用使用 AndroidX Core（`androidx.core:core-ktx`），许可证为 Apache-2.0。

H.264 和 HEVC 的硬件编解码器由设备供应商通过 Windows Media Foundation 和 Android MediaCodec 提供。ExtScreen 的 OpenH264 回退编码器从源码编译。Cisco 提供的专利许可仅覆盖其发布的预编译二进制文件。
