# Prism UI 跨平台开发指南

ExtScreen 用 Flutter 和 Prism UI 构建 Windows 控制面板、Android 连接页与串流控制浮层。本文从 ExtScreen 的实现出发，说明怎样在另一款桌面与移动端工具中复用同样的界面结构。涉及配对、视频和输入的集成做法以 ExtScreen 为例。

## 1. 版本与上游源码

| 项目 | ExtScreen 的基线 | 如何复用 |
| --- | --- | --- |
| Flutter / Dart | FVM 固定 Flutter 3.50.0，Dart 随 SDK 提供。应用声明 Dart `>=3.14.0 <4.0.0` | 同时提交 SDK 版本、依赖声明和锁文件。从 Flutter 应用目录执行 FVM 命令。 |
| Prism UI | [仓库内源码](../ui/vendor/prism_ui/EXTSCREEN_UPSTREAM.md)固定到 `8a4ca42d4205f01486da397cb7f89ba5a8071139`，上游元数据仍为 0.1.3 | 用相对路径解析，升级时先对照[上游差异][prism-compare]，再逐项复验本地补丁。 |
| FlClash 参考 | commit `afe7136002271fd64f098b154e7fff40be721eb8`，其 `plugins/prism_ui` 子模块指向 `6c47901cc80b5325bdb9650579ca2e000a60b39e` | 把应用的布局、路由和交互组织当作参考。子模块提交与 pub 发布包分别核对。 |
| Windows | Flutter x64 Runner、MSVC、Windows SDK、Rust 主机 | 在一个进程中可直接调用本地接口。跨进程时可以用有边界的 IPC，ExtScreen 使用本地命名管道。 |
| Android | Gradle Wrapper、JDK 17、Android SDK 36、NDK。应用 `minSdk 26`、`targetSdk 34`、`compileSdk 36` | Flutter 可以是独立应用，也可以嵌入既有 Activity。ExtScreen 由既有 Gradle 工程打包。 |

仓库中的基线见 [ui/.fvmrc](../ui/.fvmrc)、[ui/pubspec.yaml](../ui/pubspec.yaml)、[ui/pubspec.lock](../ui/pubspec.lock) 和 [Android Gradle 配置](../client/app/build.gradle.kts)。FlClash 的依赖声明指定了本地子模块，发布工作流也使用 Flutter 3.50.0。[FlClash 依赖声明][fl-pub] · [FlClash 发布工作流][fl-build] · [Prism UI 0.1.3 发布包][prism-package]

Prism UI 0.1.3 的包元数据将 Flutter 下限写为 3.47.0。ExtScreen 实际构建时，Flutter 3.47.6 的公共导出无法为该包提供它使用的 `ScrollCacheExtent`，应用代码静态检查可以通过，但 Flutter 测试编译会失败。使用 3.50.0 作为本项目的已验证基线。迁入另一项目时同样要做一次真实的 `flutter test` 或构建。[Flutter 3.50.0 viewport 导出][flutter-viewport] · [FlClash 工具链记录][fl-project]

该提交比 0.1.3 标签多 28 个提交。采用了 Dock 宽度、紧凑列表测量和玻璃裁切改进。保留上游 LICENSE 与 NOTICE，不修改全局 Pub 缓存。日后同步上游，先比较下列本地修正，确认回归已由新代码覆盖方可移除。

- `navigation_dock.dart` 保持已选项抬起和静止两层的图标及文字主色一致。玻璃亮度可单独变化，弹簧归位后换层时前景不跳色。
- `popup.dart` 保留收回到锚点的运动，在最后 140 ms 渐隐回收盘的填充、玻璃和阴影。锚点快照保留到实际按钮接管，延迟提交的选项不会在回收中途移动锚点。
- `app.dart` 用 `manageSystemUiOverlayStyle` 关闭 Android 嵌入壳中的 Prism 全局系统栏样式，避免和原生窗口重复写入。

上游源码分两层。Prism UI 定义组件、颜色、图标绘制、尺寸、动画与着色器。FlClash 在这一层之上添加导航状态、自己的规则与代理界面。ExtScreen 直接依赖独立的 Prism UI 包，用自己的连接、配对和串流状态填充相同组件。[FlClash UI 分层][fl-architecture] · [Prism UI 公共导出][prism-barrel]

## 2. 应用结构和平台边界

| 层 | 放什么 | ExtScreen 实例 |
| --- | --- | --- |
| 应用入口 | 主题、语言、导航根、窗口尺寸上下文 | [main.dart](../ui/lib/main.dart) 以 `PrismApp` 建立公共上下文，用 `ViewScope` 向下提供视口。 |
| 页面与状态 | 页面布局、选择、展示状态、命令回调 | [Windows 控制面板](../ui/lib/windows_screen.dart)、[Android 连接和设置](../ui/lib/android_screen.dart)、[串流控制](../ui/lib/stream_overlay.dart) |
| 平台适配 | 消息编码、原生桥接、Activity 或窗口生命周期 | [Windows 桥](../ui/lib/windows_bridge.dart)、[AndroidUiChannel.kt](../client/app/src/main/java/com/extscreen/AndroidUiChannel.kt)、[外观设置桥](../client/app/src/main/java/com/extscreen/AppearanceChannel.kt) |
| 领域逻辑 | 连接、配对、画面采集、视频解码、输入和光标 | [主机 IPC 服务](../host/src/dashboard.rs)、[连接 Activity](../client/app/src/main/java/com/extscreen/ConnectActivity.kt)、[串流 Activity](../client/app/src/main/java/com/extscreen/MainActivity.kt) |

页面提交语义化命令，例如刷新主机状态、选择帧率或断开连接。领域层决定命令是否生效，并回传新的快照。桌面 `HostBridge` 在 isolate 中等待管道 I/O，让窗口拖动和动画在等待主机时仍可响应。Android 用 `MethodChannel` 发命令、`EventChannel` 收快照，Kotlin 桥对相同状态做去重。手写笔坐标、光标位图、视频帧和高频解码数据按原生路径流动。[Windows 桥](../ui/lib/windows_bridge.dart) · [Android 状态桥](../client/app/src/main/java/com/extscreen/AndroidUiChannel.kt)

公共入口可以写成以下结构。`UiLocalizations` 是 Prism UI 对自身按钮、菜单和可访问名称的翻译接口，应用自己的页面文字由应用提供。

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

Widget toolApp({
  required Widget home,
  prism.ThemeMode themeMode = prism.ThemeMode.system,
  required Locale locale,
  required bool mobileGlass,
  required LocalizationsDelegate<prism.UiLocalizations> prismStrings,
}) {
  prism.ThemeData palette(Brightness brightness) => prism.ThemeData(
    colorScheme: prism.ColorScheme.fromSeed(
      seedColor: const Color(0xFF236DD8),
      brightness: brightness,
      style: prism.ColorStyle.tinted,
    ),
  );
  return prism.PrismApp(
    theme: palette(Brightness.light),
    darkTheme: palette(Brightness.dark),
    themeMode: themeMode,
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: [prismStrings, GlobalWidgetsLocalizations.delegate],
    liquidGlass: mobileGlass ? prism.LiquidGlassQuality.standard : null,
    builder: (context, navigator) {
      final size = MediaQuery.sizeOf(context);
      return prism.ViewScope(
        size: size,
        isMobile: size.width <= 600,
        child: navigator!,
      );
    },
    home: home,
  );
}
```

入口完整实现见 [main.dart](../ui/lib/main.dart)，委托实现见 [appearance.dart](../ui/lib/appearance.dart)。Windows 使用紧凑密度，Android 使用标准密度并启用标准玻璃质量。两者共享色彩、文字样式和内容组件。PrismApp 包含玻璃捕获宿主、文本尺寸上下文和路由。在另一个 Flutter 路由树中单独测试 Prism 控件时，也提供同样的上层配置。[Prism App 源码][prism-app] · [FlClash 应用入口][fl-app]

## 3. 导航、页面宽度与焦点

把**窗口宽度**和**内容宽度**分开处理。前者决定主导航形态，后者用于判断扣除侧栏、安全区和页面边距后能否分栏。`MediaQuery.sizeOf(context)` 得到窗口逻辑大小，内容区的 `LayoutBuilder` 得到实际分配给该区域的约束。

| 场景 | 主导航 | 内容布局 |
| --- | --- | --- |
| 窗口宽度 ≤600 | 浮动 `NavigationDock`，保留底部触控和系统安全区 | 单列，按操作顺序堆叠。 |
| Windows 宽度 >600、<840 | 紧凑 `NavigationSidebar` | 可用内容宽度达到 640 时，Windows 控制面板将相关分组并列。 |
| Windows 宽度 ≥840 | 侧栏允许就地展开或收起 | 主内容上限 1080，超宽窗口仍控制阅读跨度。 |
| Android 宽度 >600、<940 | 侧栏紧凑呈现 | Android 连接页的可用内容宽度达到 760 后，有线与局域网分别成列。 |
| Android 宽度 ≥940 | 侧栏可就地展开或收起 | 连接内容上限 1056，外观页上限 680，标题和各分组共用起始边。 |

表中的阈值均为逻辑像素，属于 ExtScreen 的布局决策。实际转向点以内容能容纳导航项、表单文字和操作按钮为准。平板分屏后可回到单列，手机横屏也可能切换到侧栏。来自其他产品的导航栏目应重新按本产品任务划分。[FlClash 响应式布局][fl-layout] · [FlClash HomePage][fl-home] · [ExtScreen Windows 布局](../ui/lib/windows_screen.dart) · [ExtScreen Android 布局](../ui/lib/android_screen.dart)

- 用同一个当前目的地状态驱动 Dock 和侧栏。切换主目的地时，连接订阅与当前设备状态仍由页面外层持有。可滚动页面用稳定的 `PageStorageKey` 保存位置。
- Dock 本身覆盖内容时，按 `NavigationDock.insetOf(context)` 给滚动内容留出底部空间，再与系统底部安全区取需要的间距。切换到侧栏后，内容可利用更完整的高度。
- `PrismScaffold` 的顶栏可以浮在正文上。分组页面从 `context.sectionsTopPadding` 起排，让 `ListHeader` 自己的上边距与顶栏接合。固定区域用 `AppBarClearance` 让出空间。对同一层级只留一次顶边距。
- 侧栏组件负责所选状态、文字和指示条。保留键盘 Tab 顺序、菜单焦点以及系统返回行为。若每个目的地有多级页面，可给目的地自己的 Navigator，让此区域的返回和弹层留在同一上下文内。

上述布局对齐由 Prism 组件自己的尺寸和层级实现，调用端指定内容约束和平台规则。[FlClash 导航与路由约定][fl-architecture] · [Prism 导航 Dock][prism-dock] · [Prism 页面框架][prism-scaffold]

## 4. 表面、密度、字阶与图标

用 `SurfaceLevel` 描述相邻界面层。调用端在容器边界传递 `SurfaceScope`，由控件读取 `context.colorScheme` 和当前层级。这样同一个列表行可以在页面或较高的弹层中使用，在浅色和深色各自保持足够的层间区分。

| 层级 | 常见内容 | ExtScreen 用法 |
| --- | --- | --- |
| `page` | 页面主体、工作区、一般 Sheet 的底色 | 连接和设置正文，串流控制浮窗的底层 |
| `card` | 分组列表、相对于页面抬高的内容块 | 连接方式、外观设置、配对与串流信息 |
| `block` | 卡片内的选择器、局部容器 | 小型预览或需要与所属卡片分隔的控制 |
| `inset` | 块内的图标托底、状态标记和轨道 | 辅助表达，不再叠第五层容器 |

浮动层用 `SurfaceLevel.floatingOf(colorScheme)` 取得当前主题的浮动表面级别。平铺内容主要用填色确立层次，分组内部用分隔线；焦点、错误和已选状态由主题色或形状标记。需要明确强调主要操作时再用 `FilledButton`。[FlClash 表面、状态和按压规范][fl-surfaces] · [Prism 表面层源码][prism-surface]

- 正文、标题、注释用 `AppTextStyle` 的现有角色。PIN、帧率和码率需要数值稳定对齐时使用等宽数字。文本放大时优先让内容换行、滚动或重排。
- 连续圆角用 `AppShape`、`AppRadius` 和 `AppCorner`。分组行交给 `DecorationListItem`。外缘圆角随组内位置变化，行与行之间共享底色并在标题处起细分隔线。
- 使用 `GlyphIcon` 和 `Glyph` 语义化呈现功能，只有图标的按钮给出 `tooltip` 或语义标签。选中或聚焦可以交给 Prism；文字与图标的状态仍可分别读出。
- Windows 使用 `VisualDensity.compact`。Android 保留标准密度、足够的触控区域和允许字体放大的行布局。和设置页、浮层一起检查长翻译、键盘焦点和系统安全区。

上游对字阶、图标和动态反馈的要求见 [FlClash UI 工作指南][fl-ui]。ExtScreen 的样式和内容边界见 [DESIGN.md](../DESIGN.md)。

## 5. 用分组行和弹出选项代替通栏开关

一组设置使用 `generateSection`，可选用 `title` 和必要的 `footer`。单行是 `DecorationListItem`。组生成器向行提供位置，分隔线与圆角因此能在增删行后正确更新。连续分组以外的单张状态卡才直接使用 `Card`。

### Windows 分组接缝的栅格修复

用实际 Windows 窗口复查分组卡片，尤其是深色主题下的浅暗细纹。Prism 对首行绘制上圆角、对末行绘制下圆角、对中间行绘制直角。截图中的斜短纹只出现在有部分圆角的行一侧，在连续三行分组的两个接缝处方向相反。分隔线是水平矩形，排查应先看逐行绘制的填色覆盖和分数像素位置。[Prism 分组行源码][prism-list-selected] · [Prism 分隔线源码][prism-separator]

ExtScreen 保留原有的 Prism 行、按压、焦点及标题对齐分隔线，仅给 Windows 多行分组加一层同色基底。基底在外缘使用 `AppShape.xl`，颜色取当前 `SurfaceScope` 的下一层，与行的实际填色一致。单行仍走 `generateSection`。这个写法可用于其他使用 Prism 0.1.3 的 Windows 页面。

```dart
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as p;

Widget windowsInsetGroup(String title, List<Widget> rows) {
  if (rows.length < 2) {
    return p.generateSection(title: title, items: rows);
  }
  return Column(children: [
    p.ListHeader(title: title),
    Builder(builder: (context) {
      final fill = p.SurfaceScope.of(context).next
          .colorOf(p.Theme.of(context).colorScheme);
      return DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: p.AppShape.xl),
        child: p.generateGroup(rows),
      );
    }),
  ]);
}
```

持久回归测试在 `flutter_tester` 中以 125%（DPR 1.25）、1350 × 900 物理像素运行真实的 `WindowsScreen`，并加入 0.25 逻辑像素的纵向偏移。测试在分组左侧、标题分隔线开始之前采样接缝上下的 7 个物理像素。浅色对照中，修复前有采样点的红通道从基底的 253 降到 250，修复后 7 点均与基底一致。另一次使用截图深色填色的离屏 Canvas 对照覆盖了多个 DPR 与分数位置。125% 的结论适用于离屏回归，实际跨屏拖动仍按第 7 节验证。[Windows 分组实现](../ui/lib/windows_screen.dart) · [分组像素回归测试](../ui/test/windows_screen_test.dart)


配置项有几种常见形态。

| 需求 | 控件组合 | 交互 |
| --- | --- | --- |
| 开关 | `DecorationListItem` + `Switch` | 行与开关写入同一个布尔值，开关带可访问标签。 |
| 单项枚举 | `DecorationListItem` + `PopupAnchor` + `PopupMenu` | 行尾展示当前值，点击整行也能打开菜单，选中项勾选。 |
| 一个文本值 | `showFloatingDialog` + `AlertDialog` + `TextField` | PIN 或手动地址在对话框输入，校验失败留在当前对话框。 |
| 多字段表单 | `showFormSheet` + 应用自己的表单行 | 由 Prism 按视图大小选择底部或居中表单面板。FlClash 将行封装为应用层的 `FormRow`。 |
| 发起连接或执行动作 | 分组行的 `onPressed` | 连接命令复用既有流程。前往另一个页面时才用披露箭头提示层级。 |

下面的选项行可以放进任一 `generateSection(items: [...])`。使用 `Flexible` 让实际呈现的值为末尾的选择符留出空间。弹层入口由同一锚点提供，行点击与行尾按钮一致。

```dart
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

Widget densityRow({
  required bool compact,
  required ValueChanged<bool> update,
}) {
  const options = [(false, '标准'), (true, '紧凑')];
  final label = compact ? '紧凑' : '标准';
  PopupOpen? open;
  return DecorationListItem(
    title: const Text('内容密度'),
    onPressed: () => open?.call(),
    trailing: PopupAnchor(
      targetBuilder: (show) {
        open = show;
        return TextButton(
          onPressed: show,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Flexible(child: PopupValueText(label)),
              const GlyphIcon(Glyphs.picker, size: 16),
            ],
          ),
        );
      },
      popupBuilder: (_) => PopupMenu(items: [
        for (final (value, title) in options)
          PopupMenuItem(
            label: title,
            checked: value == compact,
            onPressed: () => update(value),
          ),
      ]),
    ),
  );
}
```

这是为指南编写的例子。ExtScreen 的两端用这种方式实现语言、主题、帧率、码率与笔设置。帧率和码率保留一并应用的操作，避免连续选择时重复请求串流参数更新。单独的触控设置可即时提交。只把影响操作的说明放在组脚注里，字段行主要展示当前值。[FlClash ListItem 与选项行][fl-list] · [FlClash 设置行调用方][fl-settings] · [Prism Popup 源码][prism-popup] · [ExtScreen 选项行](../ui/lib/android_screen.dart)

## 6. Android 串流浮层与原生视图

ExtScreen 有连接页和一个透明的 `/stream` 路由。串流 Activity 使用独立 Flutter 壳提供控制，已有的 `SurfaceView` 与原生笔迹、光标层继续承担显示与高频输入。Prism 的玻璃能采样同一 Flutter 场景内的背景。原生 `SurfaceView` 的解码画面由系统另行合成，浮层可以呈现透光和玻璃边缘，着色器不会重折射这层解码画面。这样也省去了把视频逐帧读回 Flutter 的开销。

### 右上角控制浮窗

浮窗停靠在安全区内的右上角，由可用宽高决定列数。窄屏单列，空间充足时把选项分成两列，尽量在一页容纳状态、设置和应用操作。字体放大、键盘或短窗使高度不足时，面板内部滚动。紧凑布局依靠简短标签、并排数值和恰当的分组，保留触控命中尺寸和图标的语义标签。

半透明背景使用连续圆角和足够的底色不透明度，分别用明暗桌面检查标签对比。串流视频由系统合成，Flutter 不为了增强模糊逐帧回读视频。

1. `streamHitAreas` 上报布局后的逻辑像素矩形。Kotlin 用当前密度映射，命中控制入口、快捷键、缩放图或面板时才交给 Flutter。
2. 主浮窗以局部命中区实现画面穿透，动画退场时保留还在显示的命中区。帧率、码率、触控模式、压力曲线、笔身按键和本地笔迹在各自的值按钮上使用 `PopupAnchor` 和 `PopupMenu`。以勾选状态标识当前值，主浮窗保持原位。帧率和码率的菜单只更新草稿，由「应用」提交；触控与笔选项收回后即时生效。
3. 子菜单由 Prism 处理定位、液态玻璃、点击外部关闭和锚点快照。它可能超出主浮窗的矩形，所以 Android 只在子路由从展开到 `completed` 期间接管完整的轻触范围，避免点击菜单外侧误操作 Windows。系统返回键先关闭子菜单，收回完成后恢复主浮窗的局部命中区。
4. 首指按下时确定整个手势的接收端，越过边缘不能换接收端。旋屏需结束旧坐标下的手势，并重新发布新视口的浮窗矩形。

[串流浮窗](../ui/lib/stream_overlay.dart) · [原生浮层宿主](../client/app/src/main/java/com/extscreen/StreamControlsView.kt)

### Android 系统栏和 HyperOS

连接页使用 edge-to-edge，背景填到系统栏，交互元素仍避让安全区。实际浅色主题使用深色系统图标，实际深色主题使用浅色图标。串流页的系统栏采用 Android 沉浸和临时唤出策略。原生窗口负责透明度、图标对比和前后台恢复，Flutter 只在有效亮度变化时调用 `setEffectiveDark`。在原生拥有窗口时关闭 Prism 自动系统栏样式，避免在 HyperOS 上互相覆盖。测试手势导航、三键导航、状态栏唤出和两种主题。[Android edge-to-edge][android-edge] · [Android 沉浸模式][android-immersive] · [应用入口](../ui/lib/main.dart) · [原生系统栏](../client/app/src/main/java/com/extscreen/WindowChrome.kt)

### 重力旋屏与实时串流参数

串流 Activity 设置 `fullSensor`，仅此页面允许在系统全局方向锁定时随重力旋转。活动接收方向和窗口配置变化。用实际面板尺寸和刷新率能力向主机协商，避免用 Flutter 逻辑像素作为 Windows 分辨率。连接页维持系统方向设置。在平板分屏与系统桌面窗口中，平台可能决定活动的最终方向，以实际配置回调为准。[Android 大屏方向说明][android-orientation]

- 客户端发出 `SetDisplayOrientation`，主机重新设置已启用的 MttVDD，再读取 Windows 实际显示模式。镜像时状态仍反映主屏实际方向和分辨率。
- `ServerConfig` 负责解码器所需的分辨率、帧率与编解码器，`StreamState` 为两端界面提供主机权威状态。尺寸变化时先发新配置再发送新尺寸关键帧，丢弃旧尺寸队列，并更新光标和触控的坐标映射。
- 区分实际显示刷新率、编码帧率、用户设定的帧率或码率上限和自适应编码目标。两端显示主机回报的结果，避免把本机面板参数或尚未应用的编辑值当成实际串流值。
- 控制消息以追加方式保留已有握手与编号。两端同时更新才能完整验证旋屏和状态同步。用扩展模式做一次横向 → 纵向 → 横向，分别在 Windows 和 Android 更改限制，观察另一端状态刷新。补测镜像、断线、睡眠恢复及浮窗外手势。

[Android 串流 Activity](../client/app/src/main/java/com/extscreen/MainActivity.kt) · [控制协议](../common/src/protocol.rs) · [主机传输](../host/src/transport/server.rs)

DAWN 与小米 Pad 7 Ultra 的联调记录为 3200 × 2136 → 2136 × 3200 → 3200 × 2136，旋屏均为 120 Hz，扩展会话保持连接。Windows 将目标码率临时设为 35 Mb/s 时，安卓浮窗随即显示 35.0 Mb/s。从安卓选 90 FPS 后，Windows 读回 90 FPS 与 90 Hz。

## 7. Windows 窗口与每显示器 DPI

同一个控制面板在 100% 与 150% 缩放的显示器之间拖动时，窗口的物理像素要跟着测量环境变化，按钮、分栏阈值和文字仍按同一套逻辑像素布局。控件大小和 Win32 顶层窗口位置分别归属 Flutter 和 Runner。

| 边界 | 负责的坐标或动作 |
| --- | --- |
| Runner manifest | 声明 `PerMonitorV2`。Windows 识别此进程支持按显示器切换 DPI。 |
| Win32 顶层窗口 | 创建时用目标显示器 DPI 换算初始像素大小。收到 `WM_DPICHANGED` 时采用 Windows 建议的 `RECT`，用 `SetWindowPos` 应用新位置与尺寸。 |
| Flutter 嵌入窗口 | 顶层事件送入 Flutter，`WM_SIZE` 更新客户区。布局、断点和 Insets 按逻辑像素处理。 |
| 独立的远程显示 | 远程视频分辨率、采集范围和 Windows 指针坐标由原有主机逻辑维护。 |

写布局时直接读 `MediaQuery.sizeOf(context)` 或 `LayoutBuilder` 的约束；只在需要跨到原生窗口边界时换算物理像素。96 DPI 下 800 逻辑像素约为 800 物理像素，144 DPI 下同样 800 逻辑像素约为 1200 物理像素。再乘一次 DPI 会使分栏阈值和尺寸在跨屏时跳变。测试要拖回原屏，并观察窗口是否保持逻辑尺度。系统标题栏保留原生拖拽、最大化、恢复和任务栏行为。[Runner manifest](../ui/windows/runner/runner.exe.manifest) · [Win32 窗口实现](../ui/windows/runner/win32_window.cpp) · [Flutter 消息转发](../ui/windows/runner/flutter_window.cpp) · [Microsoft WM_DPICHANGED][ms-dpi]

### 虚拟显示驱动与当前会话

驱动管理位于 Windows「设置 → 虚拟显示驱动」。Flutter 面板和常驻主机以当前用户身份运行。点击安装或确认卸载后，主机在后台启动同一可执行文件的专用驱动命令，仅通过 Windows `runas` 为这个子进程请求管理员授权。签名驱动包的位置由主机按发布或开发目录解析。常驻主机持有驱动操作与串流会话共用的显示资源许可，有设备连接时须先断开，提权和驱动更新期间也会暂缓新的串流会话。[驱动操作和提权边界](../host/src/driver_control.rs) · [驱动安装、探测和路径](../host/src/driver_setup.rs) · [会话资源互斥](../host/src/transport/server.rs)

`install_display_driver` 和 `uninstall_display_driver` 的即时响应表示请求已受理或已处于目标状态。面板继续轮询 `status.display_driver`，通过 `operation`、`error` 与 `restart_required` 呈现正在处理、取消授权、失败或需要重启。后端以实际 PnP 设备状态判断驱动是否可用；`bundle_available` 单独说明安装所需文件是否可定位。等待重启、操作繁忙或设备连接时，禁用不适用的驱动按钮。[主机命令和状态接口](../host/src/dashboard.rs) · [Prism 驱动设置分组](../ui/lib/windows_screen.dart)

驱动可用性和当前视频来源是两个状态。用户连接后，`stream_mode: extended` 表示捕获源确实是受 ExtScreen 管理的虚拟副屏；`fallback` 表示当前在镜像主显示器。界面从当前捕获源显示「主显示器」或「虚拟显示器」。检查状态时，应实际连接并查看 Windows 的显示布局与捕获来源，再核对面板的提示。[捕获来源与模式发布](../host/src/capture/wgc.rs) · [状态字段生成](../host/src/driver_control.rs)


## 8. 语言和主题

`AppearanceController` 管理语言与深浅色，由 `PrismApp` 读取，页面从同一偏好取得本地化文字。Android 通过小型通道把偏好写到原生首选项，两条 Flutter 启动路径分别载入。Windows 保存到用户本地应用数据目录。首次打开默认选中「跟随系统」，持续响应系统主题变化。已有 `dark: bool` 迁移为明确的深色或浅色，保留用户原选择；`themeMode` 中显式保存 `system`、`light` 或 `dark`。Windows 标题栏与 Android 系统栏使用实际亮度，避免把「跟随系统」当作某个固定颜色。主题切换保持当前目的地和原生连接。

- 使用 `ExtScreenUiDelegate` 提供 Prism 内置提示，再由产品层实现标签、状态和错误提示。ExtScreen 当前语言为简体中文和英文，应用文字使用 `AppearanceController.text`。文字规模扩大时，可按 Flutter 的生成式本地化组织 ARB，保留自定义 `UiLocalizations` 委托。
- 让失败码表达具体动作。配对过多失败、电脑拒绝、版本不同等原因要给相应的处理路径。主机名、地址和用户输入按原始值显示；应用生成的后备名称再按语言替换。
- 同时检查主题切换后的当前页面、侧栏选中态、菜单、对话框和 Windows 标题栏。串流视频仍由远程电脑提供，客户端的浅色或深色设置改变的是控制界面。

[ExtScreen 偏好和本地化接口](../ui/lib/appearance.dart) · [Android 偏好通道](../client/app/src/main/java/com/extscreen/AppearanceChannel.kt) · [Flutter 应用国际化][flutter-l10n]

Windows 继续使用 Prism 默认的 Segoe UI 绘制其已有字符，缺字时按顺序回退到系统的 `Microsoft YaHei UI` 与 `Microsoft YaHei`。回退配置放在两套共用的主题入口，在浅色和深色同时生效，对中文界面文案以及英文界面中的中文主机名都适用。Android 维持自己的系统字体。发布包通过系统字体名称引用这两套字形，包内无需另带字体文件。[Windows 字体配置](../ui/lib/main.dart) · [Prism 平台默认字体][prism-theme-data]

```dart
// 设置 ThemeData 的回退列表，主字体由 Prism 按平台选择。
fontFamilyFallback: Platform.isWindows
    ? const ['Microsoft YaHei UI', 'Microsoft YaHei']
    : null,
```


## 9. 开发环境与验证

ExtScreen 的共享 Flutter 工程在 `ui/`。DAWN 上按本机环境管理规范配置 FVM、`FVM_CACHE_PATH`、`PUB_CACHE` 和 Android SDK。换机器时沿用相同的变量和项目版本锁定，并使用该机器自己的路径。Windows C++ 工具链由 Visual Studio 安装器管理。将 FVM 加入 `PATH`，也可通过 `EXTSCREEN_FVM_EXE` 指定项目使用的 FVM。安卓构建通过 `ANDROID_HOME`、按需的 `ANDROID_NDK_HOME` 和 `EXTSCREEN_JAVA_HOME` 定位本机工具。

从仓库根目录运行 Flutter 检查：

```powershell
Push-Location .\ui
try {
    fvm install
    fvm flutter pub get
    fvm flutter analyze
    fvm flutter test
} finally {
    Pop-Location
}
```

构建两个平台，或生成完整安装包：

```powershell
cargo build --release --locked --bin extscreen-host
.\scripts\build_windows_ui.ps1
.\scripts\build_android.ps1

# 行为验证通过后，按完整发布流程运行 Rust 测试并生成安装包。
.\scripts\build_release.ps1
```

Android 调试输出见 `client\app\build\outputs\apk\debug\app-debug.apk`。Windows 面板位于 `ui\build\windows\x64\runner\Release\`，依赖同目录的 DLL 和 `data\`，安装时按整个目录部署。发布签名、Cargo Android ABI、Windows 便携 ZIP 和输出目录见 [README 构建说明](../README.md#从源码构建)。调试真机与发布通用 APK 分别验证支持的 ABI。构建产物、Pub 缓存、Java/Android SDK 路径与签名配置属于本机环境，依赖版本和锁文件归项目维护。

### Windows 便携包的路径约定

Flutter Runner、运行库和 `data/` 保持相邻，常驻主机和驱动放在 `support/` 下。用户解压整个目录后打开 `ExtScreen.exe`。同一结构也适合用手工启动验证打包，日常源码调试仍用上一节的构建命令。

```text
ExtScreen.exe
flutter_windows.dll
data/
support/
  extscreen-host.exe
  driver/
    vdd_settings.xml
    vdd/
      MttVDD.inf
```

控制面板按自身可执行文件的位置寻找 `support/extscreen-host.exe`，兼容旧版本同目录的后端和仓库的 `target/` 开发布局；显式配置 `EXTSCREEN_HOST_EXE` 时使用该路径。启动后端时将控制面板的完整路径传入 `EXTSCREEN_DASHBOARD_PATH`，供托盘操作唤回同一面板。后端独立按自身的路径找到随包的 `driver/vdd/` 与分辨率配置。用完整解压目录验证一遍托盘重开、主机状态和驱动文件探测，避免用工作目录偶然掩盖相对路径问题。[便携 ZIP 脚本](../scripts/package_windows.ps1) · [Flutter 启动桥](../ui/lib/windows_bridge.dart) · [驱动包解析](../host/src/driver_setup.rs)


| 检查 | 验证方法 |
| --- | --- |
| 手机和宽屏 | 运行 [Android widget 测试](../ui/test/android_screen_test.dart)，它覆盖 350×620 手机、1100×720 宽屏、配对、偏好和串流面板。按需补充真实手机、平板横竖屏、分屏和键盘弹起。 |
| Windows 界面 | 运行 [Windows widget 测试](../ui/test/windows_screen_test.dart)，再检查窄窗与宽窗里的概览、配对和设置。用 125% 离屏像素用例检查组内接缝；实际用不同缩放的显示器来回拖动，检查逻辑尺寸与焦点。 |
| 行与弹层 | 打开菜单再变更语言和主题，检查勾选值、弹层宽度、长文字和关闭后的焦点。核对滚动不把焦点藏在悬浮顶栏下。串流时打开靠近屏幕边缘的子菜单，验证外点关闭、返回顺序、选中后淡出、只提交编辑过的串流限制，以及收回后立刻恢复画面外部触控。 |
| 串流 | 设备首次配对、同端重连、断线回到连接页。打开再关闭控制浮层后，验证画面、光标皮肤、触控和笔迹。检查从视频区域开始拖动跨过控制入口时的输入归属。 |
| 性能与可读性 | 分别看实际手机和平板的 DPI、帧率和字重。浅色、深色，以及明暗远程桌面上都检查清晰度。遇到玻璃问题时用真实 Android 图形后端确认，而非只依据 widget 截图。 |

回归排查从受影响的边界开始。DPI 只在跨屏出错时，检查 Runner 和物理像素转换。刷新率选择变化却没有视频变化时，比较 Dart 命令、Kotlin 生效值与主机状态。只有弹层覆盖时丢笔或鼠标输入时，检查 `streamHitAreas` 的矩形和首指手势归属。依赖升级后从两端完整构建和渲染开始复验。

## 10. 参考与许可

本指南中的 Dart 示例为独立编写的示例，可从实际界面代码追踪相同职责。Prism UI 和 FlClash 上游均采用 GPL-3.0，Prism UI 的 `NOTICE` 另列明其第三方实现及许可。使用 Prism UI 或移植上游代码时，按要交付的软件和实际用到的依赖核对许可证、源代码交付要求和第三方声明。ExtScreen 的项目授权与第三方许可详情见 [LICENSE](../LICENSE) 和 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。[Prism UI 许可证][prism-license] · [Prism UI NOTICE][prism-notice] · [FlClash 许可证][fl-license]

[fl-pub]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/pubspec.yaml
[fl-build]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/.github/workflows/build.yaml
[fl-project]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/.agents/project.md
[fl-app]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/application.dart
[fl-architecture]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/.agents/architecture.md
[fl-surfaces]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/.agents/surfaces.md
[fl-ui]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/.agents/skills/ui-work/SKILL.md
[fl-layout]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/common/layout.dart
[fl-home]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/pages/home.dart
[fl-list]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/ui/list_item.dart
[fl-settings]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/widgets/config_item.dart
[fl-license]: https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/LICENSE
[prism-package]: https://pub.dev/packages/prism_ui/versions/0.1.3
[prism-barrel]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/prism_ui.dart
[prism-app]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/app.dart
[prism-dock]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/navigation_dock.dart
[prism-scaffold]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/scaffold.dart
[prism-surface]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/surface.dart
[prism-popup]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/popup.dart
[prism-sheet]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/sheet.dart
[prism-glass]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/liquid_glass.dart
[prism-license]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/LICENSE
[prism-notice]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/NOTICE
[prism-list-selected]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/list_selected.dart
[prism-separator]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/list_row_separator.dart
[prism-theme-data]: https://github.com/chen08209/prism_ui/blob/8a4ca42d4205f01486da397cb7f89ba5a8071139/lib/theme_data.dart
[flutter-viewport]: https://github.com/flutter/flutter/blob/3.50.0/packages/flutter/lib/src/widgets/viewport.dart
[flutter-completed]: https://api.flutter.dev/flutter/widgets/TransitionRoute/completed.html
[flutter-l10n]: https://docs.flutter.dev/ui/internationalization
[ms-dpi]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged

[prism-compare]: https://github.com/chen08209/prism_ui/compare/v0.1.3...8a4ca42d4205f01486da397cb7f89ba5a8071139
[android-edge]: https://developer.android.com/develop/ui/views/layout/edge-to-edge
[android-immersive]: https://developer.android.com/develop/ui/views/layout/immersive
[android-orientation]: https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability
