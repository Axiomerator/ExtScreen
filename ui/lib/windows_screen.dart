import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart' as p;

import 'appearance.dart';
import 'windows_bridge.dart';

const _mobileWidth = 600.0;
const _expandedSidebarWidth = 840.0;
const _twoPaneWidth = 640.0;
const _maxContentWidth = 1080.0;

class WindowsScreen extends StatefulWidget {
  const WindowsScreen({
    super.key,
    required this.appearance,
    this.host = const HostBridge(),
  });
  final AppearanceController appearance;
  final HostBridge host;

  @override
  State<WindowsScreen> createState() => _WindowsScreenState();
}

class _WindowsScreenState extends State<WindowsScreen> {
  Map<String, dynamic>? _status;
  Timer? _poller;
  bool _working = false;
  bool _reading = false;
  int _destination = 0;
  bool _sidebarExpanded = true;
  bool _firstStatus = true;
  bool _clipboardFeedback = false;
  String? _error;
  int? _usbApprovalId;
  Route<bool>? _usbApprovalRoute;
  bool _usbApprovalStale = false;

  String t(String en, String zh) => widget.appearance.text(en, zh);
  bool get _connected => _status?['connected'] == true;

  @override
  void initState() {
    super.initState();
    widget.appearance.addListener(_appearanceChanged);
    _updateWindowTheme();
    unawaited(_start());
    _poller = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _appearanceChanged() {
    _updateWindowTheme();
    setState(() {});
  }

  void _updateWindowTheme() =>
      widget.host.setDashboardDark(widget.appearance.dark);

  @override
  void dispose() {
    widget.appearance.removeListener(_appearanceChanged);
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await widget.host.ensureRunning();
    } on Object {
      // Status polling reports whether the existing or newly started host is reachable.
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_reading || _working || !mounted) return;
    _reading = true;
    try {
      final response = await widget.host.request('status');
      final status = response['status'] as Map<String, dynamic>;
      if (!mounted) return;
      final firstStatus = _firstStatus;
      setState(() {
        _status = status;
        _firstStatus = false;
      });
      _syncUsbApproval(status);
      if (firstStatus) {
        await widget.host.request(
          'set_locale',
          widget.appearance.chinese ? 'zh' : 'en',
        );
      }
    } on Object {
      if (mounted) setState(() => _status = null);
    } finally {
      _reading = false;
    }
  }

  void _syncUsbApproval(Map<String, dynamic> status) {
    final pending = status['usb_approval'] as Map<String, dynamic>?;
    final id = pending?['id'] as int?;
    if (_usbApprovalId != null) {
      if (id != _usbApprovalId) {
        _usbApprovalStale = true;
        final route = _usbApprovalRoute;
        if (route?.isActive == true) route!.navigator?.removeRoute(route);
      }
      return;
    }
    if (id == null) return;
    _usbApprovalId = id;
    unawaited(_showUsbApproval(id, pending?['device_name'] as String?));
  }

  Future<void> _showUsbApproval(int id, String? deviceName) async {
    _usbApprovalStale = false;
    final approved = await p.showFloatingDialog<bool>(
      context: context,
      child: Builder(
        builder: (context) {
          _usbApprovalRoute = ModalRoute.of<bool>(context);
          return p.AlertDialog(
            title: t('Allow USB connection?', '允许 USB 连接？'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (deviceName != null) ...[
                  Text(
                    deviceName,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  t(
                    'Approve only when you initiated the connection on this device.',
                    '请确认是你刚刚在这台设备上发起的连接。',
                  ),
                ),
              ],
            ),
            actions: [
              p.TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(t('Deny', '拒绝')),
              ),
              p.FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t('Allow', '允许')),
              ),
            ],
          );
        },
      ),
    );
    final stale = _usbApprovalStale;
    _usbApprovalRoute = null;
    if (mounted && !stale) {
      try {
        final result = await widget.host.request('resolve_usb_approval', {
          'id': id,
          'allow': approved == true,
        });
        if (mounted && result['ok'] != true && approved == true) {
          setState(() => _error = result['error'] as String? ?? 'request');
        }
      } on Object {
        if (mounted && approved == true) setState(() => _error = 'request');
      }
    }
    _usbApprovalId = null;
  }

  Future<void> _command(String command, [Object? value]) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
      _clipboardFeedback = false;
    });
    try {
      final response = await widget.host.request(command, value);
      if (response['ok'] != true && mounted) {
        setState(() => _error = response['error'] as String? ?? 'request');
      }
    } on Object {
      if (mounted) setState(() => _error = 'request');
    } finally {
      if (mounted) {
        setState(() => _working = false);
        await _refresh();
      }
    }
  }

  String _errorText(String error) => switch (error) {
    'approval_expired' => t(
      'The USB request expired. Reconnect the device.',
      'USB 请求已过期，请重新连接设备。',
    ),
    'adb_reverse_failed' => t(
      'ADB could not forward the port. Check USB debugging and authorization.',
      'ADB 无法转发端口。请检查 USB 调试和授权。',
    ),
    'display_settings_failed' => t(
      'Open Settings → System → Display to arrange your screens.',
      '请打开「设置 → 系统 → 显示」调整显示器。',
    ),
    'settings_write_failed' => t(
      'ExtScreen could not save the host settings.',
      'ExtScreen 无法保存主机设置。',
    ),
    _ => t(
      'The host could not complete the action. Try again.',
      '主机未能完成操作，请重试。',
    ),
  };

  Widget _section(String title, List<Widget> rows) =>
      p.generateSection(title: title, items: rows);

  Widget _row(
    String label, {
    String? detail,
    String? value,
    Glyph? glyph,
    bool navigates = false,
    VoidCallback? onTap,
  }) {
    final colors = p.Theme.of(context).colorScheme;
    return p.DecorationListItem(
      leading: glyph == null ? null : GlyphIcon(glyph, size: 20),
      title: Text(label),
      subtitle: detail == null ? null : Text(detail),
      trailing: value != null
          ? Text(
              value,
              style: p.AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            )
          : navigates
          ? const GlyphIcon(Glyphs.chevronForward, size: 16)
          : null,
      onPressed: onTap,
    );
  }

  Widget _option<T>(
    String label,
    T value,
    List<(T, String)> options,
    ValueChanged<T> select, {
    required Glyph glyph,
  }) {
    final current = options.where((option) => option.$1 == value).firstOrNull;
    p.PopupOpen? openMenu;
    return p.DecorationListItem(
      leading: GlyphIcon(glyph, size: 20),
      title: Text(label),
      onPressed: _working ? null : () => openMenu?.call(),
      trailing: p.PopupAnchor(
        targetBuilder: (open) {
          openMenu = open;
          return p.TextButton(
            onPressed: _working ? null : open,
            style: p.ButtonStyle.from(
              foregroundColor: p.Theme.of(context).colorScheme.onSurfaceVariant,
              textStyle: p.AppTextStyle.callout.of(context),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: p.PopupValueText(
                      current?.$2 ?? '$value',
                      alignment: AlignmentDirectional.centerEnd,
                    ),
                  ),
                ),
                const GlyphIcon(Glyphs.picker, size: 16),
              ],
            ),
          );
        },
        popupBuilder: (_) => p.PopupMenu(
          items: [
            for (final (choice, text) in options)
              p.PopupMenuItem(
                label: text,
                checked: choice == value,
                onPressed: () => select(choice),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(String command) async {
    final forget = command == 'forget_tablets';
    final accepted = await p.showFloatingDialog<bool>(
      context: context,
      child: Builder(
        builder: (context) => p.AlertDialog(
          title: forget
              ? t('Forget paired devices?', '清除已配对设备？')
              : t('Exit ExtScreen?', '退出 ExtScreen？'),
          child: Text(
            forget
                ? t(
                    'Devices will need the PIN to pair again.',
                    '再次连接时需要输入 PIN。',
                  )
                : t('The current session will disconnect.', '当前连接将断开。'),
          ),
          destructive: forget,
          actions: [
            p.TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Cancel', '取消')),
            ),
            p.FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                forget
                    ? t('Forget devices', '清除设备')
                    : t('Exit ExtScreen', '退出 ExtScreen'),
              ),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) await _command(command);
  }

  Widget _connection() {
    final colors = p.Theme.of(context).colorScheme;
    final link = switch (_status?['link']) {
      'usb' => t('Direct USB', 'USB 直连'),
      'usb_tether' => t('USB tethering', 'USB 网络共享'),
      'wifi' => t('Local network', '局域网'),
      _ => '',
    };
    final title = _status == null
        ? t('Host unavailable', '主机未就绪')
        : _connected
        ? t('Display connected', '副屏已连接')
        : t('Ready to connect', '等待设备连接');
    final device = _status?['device_name'] as String?;
    final terminal = _status == null || _connected;

    final summary = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        p.Surface(
          color: p.SurfaceLevel.block.colorOf(colors),
          shape: p.AppShape.all(p.AppCorner.sm),
          child: SizedBox.square(
            dimension: 40,
            child: Center(
              child: GlyphIcon(
                _WindowsGlyphs.display,
                color: _connected ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                title,
                style: p.AppTextStyle.headline
                    .of(context)
                    .copyWith(color: colors.onSurface),
              ),
              Text(
                _connected
                    ? [device, if (link.isNotEmpty) link].nonNulls.join(' · ')
                    : _status == null
                    ? t('Start the host to accept connections.', '启动主机后即可连接。')
                    : t(
                        'Select this PC in ExtScreen on Android.',
                        '在安卓端 ExtScreen 中选择这台电脑。',
                      ),
                style: p.AppTextStyle.subheadline
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
    final action = terminal
        ? p.TonalButton(
            label: _connected
                ? t('Arrange displays', '排列显示器')
                : t('Start host', '启动主机'),
            onPressed: _working
                ? null
                : _connected
                ? () => _command('display_settings')
                : _start,
          )
        : null;
    return p.Card(
      inert: true,
      radius: p.AppCorner.lg,
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (action == null) return summary;
          if (constraints.maxWidth >= 520) {
            return Row(
              spacing: 12,
              children: [
                Expanded(child: summary),
                action,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [summary, action],
          );
        },
      ),
    );
  }

  Widget _pairing() {
    final colors = p.Theme.of(context).colorScheme;
    final rawPin = _status?['pin'] as String?;
    final pin = rawPin != null && rawPin.isNotEmpty ? rawPin : null;
    final paused = _status?['pairing_paused_seconds'] as int?;
    final paired =
        (_status?['paired_devices'] as List?)?.cast<String>() ?? const [];
    final port = _status?['port'] as int?;
    String addresses(String key) =>
        ((_status?[key] as List?)?.cast<String>() ?? const []).join(', ');
    final usb = addresses('usb_addresses');
    final lan = addresses('lan_addresses');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(t('Pairing', '设备配对'), [
          p.DecorationListItem(
            leading: const GlyphIcon(Glyphs.pin, size: 20),
            title: Text(t('Pairing PIN', '配对 PIN')),
            subtitle: paused != null
                ? Text(t('Available in $paused s', '$paused 秒后恢复'))
                : _clipboardFeedback
                ? Text(t('Copied', '已复制'))
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      pin ?? '—',
                      style: p.AppTextStyle.headline
                          .of(context)
                          .copyWith(
                            color: colors.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                  ),
                ),
                p.IconButton(
                  tooltip: t('Copy PIN', '复制 PIN'),
                  icon: GlyphIcon(
                    _clipboardFeedback ? Glyphs.check : Glyphs.copy,
                    size: 18,
                  ),
                  onPressed: pin == null
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: pin));
                          if (mounted)
                            setState(() => _clipboardFeedback = true);
                        },
                ),
              ],
            ),
          ),
          _row(
            t('Generate a new PIN', '更新 PIN'),
            glyph: _WindowsGlyphs.refresh,
            onTap: pin == null || _working ? null : () => _command('new_pin'),
          ),
        ]),
        if (_status != null)
          _section(t('Connection addresses', '连接地址'), [
            if (usb.isNotEmpty)
              _row(
                t('USB network', 'USB 网络'),
                glyph: _WindowsGlyphs.link,
                detail: usb,
              ),
            if (lan.isNotEmpty)
              _row(
                t('Local network', '局域网'),
                glyph: _WindowsGlyphs.network,
                detail: lan,
              ),
            if (port != null)
              _row(
                t('Host port', '主机端口'),
                glyph: _WindowsGlyphs.port,
                value: '$port',
              ),
          ]),
        if (_status != null)
          _section(t('Paired devices', '已配对设备'), [
            if (paired.isEmpty)
              _row(
                t('No paired devices', '暂无已配对设备'),
                glyph: _WindowsGlyphs.tablet,
              ),
            for (final device in paired)
              _row(device, glyph: _WindowsGlyphs.tablet),
          ]),
      ],
    );
  }

  Widget _streamOptions() {
    if (_status == null) return const SizedBox.shrink();
    final fps = _status?['fps'] as int? ?? 60;
    final bitrate = _status?['manual_bitrate_kbps'] as int? ?? 0;
    final hz = _status?['refresh_hz'] as int? ?? 0;
    final width = _status?['width'] as int? ?? 0;
    final height = _status?['height'] as int? ?? 0;
    final codec = _status?['codec'];
    final kbps = _status?['bitrate_kbps'] as int? ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_connected)
          _section(t('Current session', '当前会话'), [
            _row(
              t('Virtual display', '虚拟显示器'),
              glyph: _WindowsGlyphs.display,
              value: '$width × $height · $hz Hz',
            ),
            if (codec != null)
              _row(
                t('Video', '视频'),
                glyph: _WindowsGlyphs.video,
                value: '$codec · ${(kbps / 1000).toStringAsFixed(1)} Mb/s',
              ),
          ]),
        _section(t('Stream parameters', '串流参数'), [
          _option(
            t('Frame rate limit', '帧率上限'),
            fps,
            const [(60, '60 Hz'), (90, '90 Hz'), (120, '120 Hz')],
            (value) => _command('set_fps', value),
            glyph: _WindowsGlyphs.refresh,
          ),
          _option(
            t('Bitrate limit', '码率上限'),
            bitrate,
            [
              (0, t('Auto', '自动')),
              for (final mbps in [15, 25, 35, 50]) (mbps * 1000, '$mbps Mb/s'),
            ],
            (value) => _command('set_bitrate', value),
            glyph: _WindowsGlyphs.video,
          ),
          if (_connected)
            _row(
              t('Request a keyframe', '请求关键帧'),
              glyph: _WindowsGlyphs.display,
              onTap: _working ? null : () => _command('request_keyframe'),
            ),
        ]),
      ],
    );
  }

  void _selectDestination(int index) {
    if (index == _destination) return;
    setState(() => _destination = index);
  }

  Widget _preferences() {
    final appearance = widget.appearance;
    return _columns(
      primary: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(t('Appearance', '外观'), [
            _option(
              t('Language', '语言'),
              appearance.chinese,
              const [(false, 'English'), (true, '简体中文')],
              (value) async {
                await appearance.setChinese(value);
                if (mounted && _status != null) {
                  await _command('set_locale', value ? 'zh' : 'en');
                }
              },
              glyph: _WindowsGlyphs.language,
            ),
            _option(
              t('Theme', '主题'),
              appearance.dark,
              [(false, t('Light', '浅色')), (true, t('Dark', '深色'))],
              appearance.setDark,
              glyph: _WindowsGlyphs.appearance,
            ),
          ]),
          _section(t('Host', '主机'), [
            _row(
              t('Set up ADB reverse', '设置 ADB 反向转发'),
              glyph: _WindowsGlyphs.link,
              detail: t('Direct USB with USB debugging', '用于已开启 USB 调试的设备'),
              onTap: _status == null || _working
                  ? null
                  : () => _command('adb_reverse'),
            ),
            _row(
              t('Windows display settings', 'Windows 显示设置'),
              glyph: _WindowsGlyphs.display,
              navigates: true,
              onTap: _status == null || _working
                  ? null
                  : () => _command('display_settings'),
            ),
            _row(
              t('Forget paired devices', '清除已配对设备'),
              glyph: _WindowsGlyphs.tablet,
              onTap: _status == null || _working
                  ? null
                  : () => _confirm('forget_tablets'),
            ),
          ]),
        ],
      ),
      secondary: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(t('Window', '窗口'), [
            _row(
              t('Hide to system tray', '隐藏到系统托盘'),
              glyph: _WindowsGlyphs.minimize,
              onTap: widget.host.hideDashboard,
            ),
            _row(
              t('Exit ExtScreen', '退出 ExtScreen'),
              glyph: Glyphs.close,
              onTap: _status == null || _working
                  ? null
                  : () => _confirm('exit'),
            ),
          ]),
          p.ListHeader(title: t('Pen input test', '笔输入测试')),
          p.Card(
            inert: true,
            radius: p.AppCorner.lg,
            padding: const EdgeInsets.all(16),
            child: _PenPad(appearance: appearance),
          ),
        ],
      ),
    );
  }

  Widget _columns({
    required Widget primary,
    required Widget secondary,
    bool secondaryFirstWhenNarrow = false,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < _twoPaneWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: secondaryFirstWhenNarrow
              ? [secondary, primary]
              : [primary, secondary],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          Expanded(child: primary),
          Expanded(child: secondary),
        ],
      );
    },
  );

  Widget _overview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _connection(),
      if (_status == null)
        _pairing()
      else
        _columns(
          primary: _streamOptions(),
          secondary: _pairing(),
          secondaryFirstWhenNarrow: !_connected,
        ),
    ],
  );

  Widget _page(BuildContext context, String title, double inset, bool dock) {
    const idle = AlwaysStoppedAnimation(false);
    return p.PrismScaffold(
      bar: p.ScaffoldBar(
        isCompact: p.ViewScope.isMobileOf(context),
        listenable: idle,
        loading: AlwaysStoppedAnimation(_working),
        builder: (_) => p.AppBar(titleSpacing: inset, title: Text(title)),
      ),
      body: p.AppBarClearance(
        child: AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          switchInCurve: p.Easing.standard,
          switchOutCurve: p.Easing.standard,
          layoutBuilder: (active, outgoing) => Stack(
            fit: StackFit.expand,
            children: [
              for (final child in outgoing) IgnorePointer(child: child),
              if (active != null) active,
            ],
          ),
          child: SingleChildScrollView(
            key: PageStorageKey(_destination),
            padding: EdgeInsets.fromLTRB(
              inset,
              8,
              inset,
              dock ? p.NavigationDock.insetOf(context) + 12 : 20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: p.Card(
                        inert: true,
                        isError: true,
                        padding: const EdgeInsets.all(12),
                        child: Text(_errorText(error)),
                      ),
                    ),
                  ),
                if (_destination == 0) _overview() else _preferences(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overview = t('Overview', '概览');
    final settings = t('Settings', '设置');
    final colors = p.Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, window) {
        final compact = window.maxWidth <= _mobileWidth;
        final canExpand = window.maxWidth > _expandedSidebarWidth;
        return p.Surface(
          color: p.SurfaceLevel.page.colorOf(colors),
          child: Row(
            children: [
              p.AnimatedVisibility.sidebar(
                visible: !compact,
                child: ColoredBox(
                  color: colors.chromeSurface,
                  child: Row(
                    children: [
                      p.NavigationSidebar(
                        destinations: [
                          p.SidebarDestination(
                            glyph: _WindowsGlyphs.display,
                            label: overview,
                          ),
                          p.SidebarDestination(
                            glyph: _WindowsGlyphs.settings,
                            label: settings,
                          ),
                        ],
                        selectedIndex: _destination,
                        expanded: canExpand && _sidebarExpanded,
                        onSelected: _selectDestination,
                        onToggle: canExpand
                            ? () => setState(
                                () => _sidebarExpanded = !_sidebarExpanded,
                              )
                            : null,
                      ),
                      ColoredBox(
                        color: p.Divider.colorOf(context),
                        child: const SizedBox(
                          width: 1,
                          height: double.infinity,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, pane) {
                      final inset = math.max(
                        16.0,
                        (pane.maxWidth - _maxContentWidth) / 2,
                      );
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          FocusTraversalGroup(
                            child: _page(
                              context,
                              _destination == 0 ? overview : settings,
                              inset,
                              compact,
                            ),
                          ),
                          if (compact)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: p.NavigationDock(
                                destinations: [
                                  p.NavigationDockDestination(
                                    glyph: _WindowsGlyphs.display,
                                    label: overview,
                                  ),
                                  p.NavigationDockDestination(
                                    glyph: _WindowsGlyphs.settings,
                                    label: settings,
                                  ),
                                ],
                                selectedIndex: _destination,
                                onSelected: _selectDestination,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

abstract final class _WindowsGlyphs {
  static const display = Glyph([
    GlyphBox(3, 4, 21, 17, 2),
    GlyphPath('M12 17 V21 M8 21 H16', role: GlyphRole.line),
  ]);
  static const tablet = Glyph([
    GlyphBox(4, 3, 20, 21, 2),
    GlyphPath('M10 18 H14', role: GlyphRole.line),
  ]);
  static const settings = Glyph([
    GlyphPath(
      'M4 6 H9 M14 6 H20 M4 12 H13 M18 12 H20 M4 18 H7 M12 18 H20',
      role: GlyphRole.line,
    ),
    GlyphCircle(11.5, 6, 2.5),
    GlyphCircle(15.5, 12, 2.5),
    GlyphCircle(9.5, 18, 2.5),
  ]);
  static const refresh = Glyph([
    GlyphPath('M19.5 10 A8 8 0 1 0 19 16 M20 5 V10 H15', role: GlyphRole.line),
  ]);
  static const video = Glyph([
    GlyphBox(3, 5, 21, 19, 2),
    GlyphPath('M10 9 L15 12 L10 15 Z', role: GlyphRole.detail),
  ]);
  static const network = Glyph([
    GlyphPath(
      'M3 9 Q12 2 21 9 M6 13 Q12 8 18 13 M9 16 Q12 13 15 16',
      role: GlyphRole.line,
    ),
    GlyphCircle(12, 19.2, 1, role: GlyphRole.detail, solid: true),
  ]);
  static const link = Glyph([
    GlyphPath(
      'M8.8 10.3 L11 8.1 A3.5 3.5 0 1 1 16 13 L13.8 15.2 '
      'M15.2 13.7 L13 15.9 A3.5 3.5 0 1 1 8 11 L10.2 8.8 '
      'M10 14 L14 10',
      role: GlyphRole.line,
    ),
  ]);
  static const port = Glyph([
    GlyphBox(4, 6, 20, 18, 2),
    GlyphPath('M8 8 V11 M12 8 V11 M16 8 V11', role: GlyphRole.line),
  ]);
  static const language = Glyph([
    GlyphCircle(12, 12, 9),
    GlyphPath(
      'M3 12 H21 M12 3 C7 7 7 17 12 21 M12 3 C17 7 17 17 12 21',
      role: GlyphRole.line,
    ),
  ]);
  static const appearance = Glyph([
    GlyphCircle(12, 12, 8),
    GlyphPath('M12 4 A8 8 0 0 1 12 20 Z', role: GlyphRole.detail, solid: true),
  ]);
  static const minimize = Glyph([
    GlyphBox(3, 5, 21, 19, 2),
    GlyphPath('M8 13 H16', role: GlyphRole.line),
  ]);
}

class _PenPad extends StatefulWidget {
  const _PenPad({required this.appearance});
  final AppearanceController appearance;

  @override
  State<_PenPad> createState() => _PenPadState();
}

class _PenPadState extends State<_PenPad> {
  Offset? _point;
  double _pressure = 0;

  void _pointAt(PointerEvent event) {
    setState(() {
      _point = event.localPosition;
      _pressure = event.down ? event.pressure : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = p.Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.appearance.text('Move your pen here', '在此移动触控笔')),
        const SizedBox(height: 8),
        Listener(
          onPointerDown: _pointAt,
          onPointerMove: _pointAt,
          onPointerHover: _pointAt,
          onPointerUp: _pointAt,
          child: ClipRSuperellipse(
            borderRadius: p.AppRadius.all(p.AppCorner.sm),
            child: SizedBox(
              height: 104,
              child: ColoredBox(
                color: theme.surface,
                child: LayoutBuilder(
                  builder: (context, box) => Stack(
                    children: [
                      if (_point case final point?)
                        Positioned(
                          left: point.dx - 5,
                          top: point.dy - 5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox.square(dimension: 10),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.appearance.text(
            'Pressure: ${_pressure.toStringAsFixed(2)}',
            '压力：${_pressure.toStringAsFixed(2)}',
          ),
        ),
      ],
    );
  }
}
