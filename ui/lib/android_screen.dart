import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import 'appearance.dart';

part 'stream_overlay.dart';

const _android = MethodChannel('extscreen/android');
const _events = EventChannel('extscreen/android/events');

typedef _State = Map<Object?, Object?>;

class _Target {
  const _Target({
    required this.host,
    required this.port,
    required this.name,
    this.hostId,
    this.usbTether = false,
    this.paired = false,
  });

  factory _Target.fromMap(_State map) => _Target(
    host: map['host'] as String,
    port: map['port'] as int,
    name: map['name'] as String,
    hostId: map['hostId'] as String?,
    usbTether: map['usbTether'] == true,
    paired: map['paired'] == true,
  );

  final String host;
  final int port;
  final String name;
  final String? hostId;
  final bool usbTether;
  final bool paired;

  bool get directUsb => host == '127.0.0.1' && !usbTether;

  _State request(String? pin) => {
    'host': host,
    'port': port,
    'name': name,
    'hostId': hostId,
    'usbTether': usbTether,
    if (pin != null) 'pin': pin,
  };
}

class AndroidScreen extends StatefulWidget {
  const AndroidScreen({super.key, required this.appearance});

  final AppearanceController appearance;

  @override
  State<AndroidScreen> createState() => _AndroidScreenState();
}

class _AndroidScreenState extends State<AndroidScreen> {
  static const _usb = _Target(host: '127.0.0.1', port: 59100, name: 'USB');

  late final StreamSubscription<dynamic> _subscription;
  _State? _state;
  bool _settings = false;
  bool _pairingShown = false;
  bool _sidebarExpanded = true;
  String? _manualAddress;
  String? _localNotice;

  String text(String en, String zh) => widget.appearance.text(en, zh);

  @override
  void initState() {
    super.initState();
    _subscription = _events.receiveBroadcastStream().listen(
      (event) => _receive(event as _State),
      onError: (Object error) => _reportUnavailable(),
    );
    unawaited(_initialState());
  }

  Future<void> _initialState() async {
    try {
      final state = await _android.invokeMapMethod<Object?, Object?>(
        'getConnectionState',
      );
      if (state != null && _state == null) _receive(state);
    } on PlatformException {
      _reportUnavailable();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  void _receive(_State state) {
    if (!mounted) return;
    setState(() => _state = state);
    final pairing = state['pairing'];
    if (pairing is _State && !_pairingShown) {
      _pairingShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_pair(_Target.fromMap(pairing)));
      });
    }
  }

  void _reportUnavailable() {
    if (mounted) setState(() => _localNotice = 'unavailable');
  }

  Future<void> _call(String method, [_State? arguments]) async {
    try {
      await _android.invokeMethod<Object?>(method, arguments);
    } on PlatformException {
      _reportUnavailable();
    }
  }

  void _connect(_Target target, [String? pin]) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _localNotice = null);
    unawaited(_call('connect', target.request(pin)));
  }

  Future<void> _pair(_Target target) async {
    final pin = await showFloatingDialog<String>(
      context: context,
      child: _PairDialog(
        name: target.name,
        appearance: widget.appearance,
        error: _state?['notice'] == 'authFailed'
            ? _authNotice(_state?['noticeDetail'] as String?)
            : null,
      ),
    );
    _pairingShown = false;
    if (!mounted) return;
    if (pin == null) {
      await _call('cancelPairing');
    } else {
      _connect(target, pin);
    }
  }

  Future<void> _connectAddress() async {
    final target = await showFloatingDialog<_Target>(
      context: context,
      child: _AddressDialog(
        initialValue: _manualAddress,
        appearance: widget.appearance,
      ),
    );
    if (target == null || !mounted) return;
    _manualAddress = target.port == 59100
        ? target.host
        : '${target.host}:${target.port}';
    _connect(target);
  }

  String? _notice(String? code) => switch (code) {
    'needsPin' => text('Enter the PIN shown on the PC.', '请输入电脑上显示的 PIN。'),
    'authFailed' => _authNotice(_state?['noticeDetail'] as String?),
    'takenOver' => text('Another device took over the display.', '另一台设备已接管副屏。'),
    'usbDetached' => text(
      'USB disconnected. Reconnect the cable to resume.',
      'USB 已断开。请重新连接数据线。',
    ),
    'invalidAddress' => text(
      'Enter an IPv4 address, such as 192.168.1.20.',
      '请输入 IPv4 地址，例如 192.168.1.20。',
    ),
    'invalidPin' => text('Enter all six digits.', '请输入完整的六位数字。'),
    'unavailable' => text(
      'ExtScreen could not complete that action. Try again.',
      'ExtScreen 未能完成该操作。请重试。',
    ),
    _ => null,
  };

  String _authNotice(String? detail) {
    if (detail == null || detail.isEmpty) {
      return text(
        'Could not pair. Check ExtScreen on the PC and try again.',
        '配对失败。请检查电脑端 ExtScreen 后重试。',
      );
    }
    if (!widget.appearance.chinese) return detail;
    return switch (detail) {
      final message when message.startsWith('Wrong PIN.') =>
        'PIN 不正确。请核对电脑上显示的代码。',
      final message when message.startsWith('Too many wrong PINs') =>
        '电脑已暂停配对。请在电脑端生成新 PIN，再输入新代码。',
      final message when message.startsWith('The PC did not allow') =>
        '电脑拒绝了连接。请重新连接，并在电脑上确认允许。',
      final message when message.startsWith('The PC runs a different') =>
        '电脑与此设备的 ExtScreen 协议版本不同。请更新两端应用。',
      final message
          when message.contains('unencrypted session') ||
              message.contains('unauthenticated session') =>
        '电脑提供的网络连接不符合安全要求。请检查两端版本后重试。',
      _ => '无法验证电脑的配对信息。请检查电脑端 ExtScreen 后重试。',
    };
  }

  String _name(_Target target) =>
      target.directUsb &&
          const {
            'USB',
            'USB cable',
            'Direct USB (Plug & Play)',
          }.contains(target.name)
      ? text('Direct USB', 'USB 直连')
      : target.name;

  String _details(_Target target) {
    if (target.directUsb)
      return text(
        'ADB or Android Open Accessory',
        'ADB 或 Android Open Accessory',
      );
    return target.port == 59100 ? target.host : '${target.host}:${target.port}';
  }

  void _select(int index) {
    final preferencePage = index == 1;
    if (_settings == preferencePage) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _settings = preferencePage);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appearance,
      builder: (context, _) {
        final connections = text('Connections', '连接');
        final settings = text('Settings', '设置');
        final section = _settings ? 1 : 0;
        final page = _PrismPage(
          title: _settings ? settings : connections,
          body: _settings ? _appearance() : _connections(),
        );
        return PopScope(
          canPop: !_settings,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _settings) _select(0);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (context.isMobileView) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    BottomInsetScope(
                      inset: NavigationDock.insetOf(context),
                      child: page,
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: NavigationDock(
                        destinations: [
                          NavigationDockDestination(
                            glyph: _displayGlyph,
                            label: connections,
                          ),
                          NavigationDockDestination(
                            glyph: _settingsGlyph,
                            label: settings,
                          ),
                        ],
                        selectedIndex: section,
                        onSelected: _select,
                      ),
                    ),
                  ],
                );
              }
              final canExpand = constraints.maxWidth >= 940;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NavigationSidebar(
                    destinations: [
                      SidebarDestination(
                        glyph: _displayGlyph,
                        label: connections,
                      ),
                      SidebarDestination(
                        glyph: _settingsGlyph,
                        label: settings,
                      ),
                    ],
                    selectedIndex: section,
                    expanded: canExpand && _sidebarExpanded,
                    onSelected: _select,
                    onToggle: canExpand
                        ? () => setState(
                            () => _sidebarExpanded = !_sidebarExpanded,
                          )
                        : null,
                  ),
                  Expanded(child: page),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _appearance() {
    final appearance = widget.appearance;
    return _PageScroll(
      key: const PageStorageKey('appearance'),
      maxWidth: 680,
      children: [
        generateSection(
          title: text('Appearance', '外观'),
          items: [
            _OptionsRow<bool>(
              title: text('Language', '语言'),
              options: const [(false, 'English'), (true, '简体中文')],
              value: appearance.chinese,
              onChanged: (value) => unawaited(appearance.setChinese(value)),
            ),
            _OptionsRow<ThemeMode>(
              title: text('Color mode', '颜色模式'),
              options: [
                (ThemeMode.system, text('System', '跟随系统')),
                (ThemeMode.light, text('Light', '浅色')),
                (ThemeMode.dark, text('Dark', '深色')),
              ],
              value: appearance.themeMode,
              onChanged: (value) => unawaited(appearance.setThemeMode(value)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _connections() {
    final hosts = (_state?['hosts'] as List<Object?>? ?? const [])
        .cast<_State>()
        .map(_Target.fromMap)
        .toList();
    final lastTarget = _state?['lastTarget'];
    final last = lastTarget is _State ? _Target.fromMap(lastTarget) : null;
    final usbHosts = hosts.where((host) => host.usbTether).toList();
    final networkHosts = hosts.where((host) => !host.usbTether).toList();
    final tether = _state?['tetherActive'] == true;
    final message = _notice(_localNotice ?? _state?['notice'] as String?);
    return _PageScroll(
      key: const PageStorageKey('connections'),
      children: [
        if (message != null)
          Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  style: AppTextStyle.body
                      .of(context)
                      .copyWith(color: context.colorScheme.error),
                ),
              ),
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final wired = Column(
              children: [
                if (last != null)
                  generateSection(
                    title: text('Last connection', '上次连接'),
                    items: [
                      _ActionRow(
                        title: _name(last),
                        detail: last.directUsb
                            ? _details(last)
                            : last.usbTether
                            ? text('USB tethering', 'USB 网络共享')
                            : _details(last),
                        leading: const GlyphIcon(_displayGlyph),
                        onPressed: () => _connect(last),
                      ),
                    ],
                  ),
                generateSection(
                  title: 'USB',
                  items: [
                    for (final host in usbHosts)
                      _ActionRow(
                        title: host.name,
                        detail: _details(host),
                        leading: const GlyphIcon(_displayGlyph),
                        onPressed: () => _connect(host),
                      ),
                    _ActionRow(
                      title: tether
                          ? text('USB tethering settings', 'USB 网络共享设置')
                          : text('Turn on USB tethering', '开启 USB 网络共享'),
                      detail: tether && usbHosts.isEmpty
                          ? text('Searching over USB…', '正在通过 USB 搜索…')
                          : null,
                      leading: const GlyphIcon(_cableGlyph),
                      onPressed: () => unawaited(_call('openUsbTethering')),
                    ),
                    _ActionRow(
                      title: text('Direct USB', 'USB 直连'),
                      detail: text(
                        'ADB or Android Open Accessory',
                        'ADB 或 Android Open Accessory',
                      ),
                      leading: const GlyphIcon(_cableGlyph),
                      onPressed: () => _connect(_usb),
                    ),
                  ],
                ),
              ],
            );
            final wireless = generateSection(
              title: text('Local network', '局域网'),
              items: [
                if (networkHosts.isEmpty)
                  _ActionRow(
                    title: text('Searching for PCs…', '正在搜索电脑…'),
                    leading: const GlyphIcon(Glyphs.search),
                  ),
                for (final host in networkHosts)
                  _ActionRow(
                    title: host.name,
                    detail: _details(host),
                    leading: const GlyphIcon(_displayGlyph),
                    onPressed: () => _connect(host),
                  ),
                _ActionRow(
                  title: text('Enter PC address', '输入电脑地址'),
                  leading: const GlyphIcon(_networkGlyph),
                  onPressed: () => unawaited(_connectAddress()),
                ),
              ],
              footer: networkHosts.isEmpty
                  ? text(
                      'Open ExtScreen on a PC connected to the same network.',
                      '请在同一网络下的电脑上启动 ExtScreen。',
                    )
                  : null,
            );
            return constraints.maxWidth >= 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 16,
                    children: [
                      Expanded(child: wired),
                      Expanded(child: wireless),
                    ],
                  )
                : Column(children: [wired, wireless]);
          },
        ),
      ],
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog({this.initialValue, required this.appearance});

  final String? initialValue;
  final AppearanceController appearance;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _invalid = false;

  String text(String en, String zh) => widget.appearance.text(en, zh);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parts = _controller.text.trim().split(':');
    final host = parts.first;
    final port = parts.length == 1 ? 59100 : int.tryParse(parts.last);
    final octets = host.split('.');
    final validHost =
        octets.length == 4 &&
        octets.every((part) {
          final value = int.tryParse(part);
          return value != null &&
              RegExp(r'^[0-9]{1,3}$').hasMatch(part) &&
              value >= 0 &&
              value <= 255;
        });
    if (!validHost ||
        parts.length > 2 ||
        port == null ||
        port < 1 ||
        port > 65535) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, _Target(host: host, port: port, name: host));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: text('Enter PC address', '输入电脑地址'),
    hasFields: true,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(text('Cancel', '取消')),
      ),
      TextButton(onPressed: _submit, child: Text(text('Connect', '连接'))),
    ],
    child: TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))],
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        hintText: '192.168.1.20',
        errorText: _invalid
            ? text('Enter a valid IPv4 address and port.', '请输入有效的 IPv4 地址和端口。')
            : null,
      ),
      onChanged: (_) {
        if (_invalid) setState(() => _invalid = false);
      },
      onSubmitted: (_) => _submit(),
    ),
  );
}

class _PairDialog extends StatefulWidget {
  const _PairDialog({required this.name, required this.appearance, this.error});

  final String name;
  final AppearanceController appearance;
  final String? error;

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  String _pin = '';

  String text(String en, String zh) => widget.appearance.text(en, zh);

  void _submit() {
    if (_pin.length == 6) Navigator.pop(context, _pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: text('Pair with ${widget.name}', '与 ${widget.name} 配对'),
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(text('Cancel', '取消')),
        ),
        TextButton(
          onPressed: _pin.length == 6 ? _submit : null,
          child: Text(text('Pair', '配对')),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(
            text(
              'Enter the six digits shown in ExtScreen on the PC.',
              '请输入电脑端 ExtScreen 显示的六位数字。',
            ),
          ),
          TextField(
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            enableSuggestions: false,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: InputDecoration(
              hintText: 'PIN',
              errorText: widget.error,
            ),
            onChanged: (value) => setState(() => _pin = value),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    );
  }
}

const _displayGlyph = Glyph([
  GlyphBox(2.5, 4, 21.5, 17, 2.5),
  GlyphPath('M12 17v3M8.5 20h7', role: GlyphRole.line),
]);
const _settingsGlyph = Glyph([
  GlyphPath('M4 6h16M4 12h16M4 18h16', role: GlyphRole.line),
  GlyphCircle(8, 6, 2.2),
  GlyphCircle(16, 12, 2.2),
  GlyphCircle(10, 18, 2.2),
]);
const _cableGlyph = Glyph([
  GlyphBox(7, 8, 17, 15, 2),
  GlyphPath('M9.5 8V4M14.5 8V4M12 15v5', role: GlyphRole.line),
]);
const _networkGlyph = Glyph([
  GlyphCircle(12, 17.5, 1.1, solid: true),
  GlyphPath(
    'M7.5 14a7 7 0 0 1 9 0M4.5 10.5a11.5 11.5 0 0 1 15 0',
    role: GlyphRole.line,
  ),
]);

class _PrismPage extends StatelessWidget {
  const _PrismPage({required this.title, required this.body});

  static final _barChanges = Listenable.merge(const []);
  static final _loading = ValueNotifier(false);

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) => PrismScaffold(
    bar: ScaffoldBar(
      isCompact: false,
      listenable: _barChanges,
      loading: _loading,
      builder: (context) => AppBar(title: Text(title)),
    ),
    body: body,
  );
}

class _PageScroll extends StatelessWidget {
  const _PageScroll({super.key, this.maxWidth = 1056, required this.children});

  final double maxWidth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final inset = BottomInsetScope.of(context);
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        16,
        context.sectionsTopPadding,
        16,
        (inset > safeBottom ? inset : safeBottom) + 16,
      ),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.glyph,
    required this.onPressed,
  });

  final String label;
  final Glyph glyph;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    width: 48,
    child: IconButton(
      tooltip: label,
      icon: GlyphIcon(glyph),
      onPressed: onPressed,
    ),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    this.detail,
    this.leading,
    this.onPressed,
  });

  final String title;
  final String? detail;
  final Widget? leading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DecorationListItem(
    title: Text(title),
    subtitle: detail == null ? null : Text(detail!),
    leading: leading,
    onPressed: onPressed,
  );
}

class _OptionsRow<T> extends StatelessWidget {
  const _OptionsRow({
    required this.title,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    PopupOpen? open;
    final label = options
        .firstWhere((option) => option.$1 == value, orElse: () => options.first)
        .$2;
    return DecorationListItem(
      title: Text(title),
      onPressed: () => open?.call(),
      trailing: PopupAnchor(
        targetBuilder: (show) {
          open = show;
          return TextButton(
            onPressed: show,
            style: ButtonStyle.from(
              foregroundColor: context.colorScheme.onSurfaceVariant,
              textStyle: context.listTitleStyle,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: PopupValueText(
                      label,
                      alignment: AlignmentDirectional.centerEnd,
                    ),
                  ),
                ),
                const GlyphIcon(Glyphs.picker, size: 16),
              ],
            ),
          );
        },
        popupBuilder: (_) => PopupMenu(
          items: [
            for (final (id, text) in options)
              PopupMenuItem(
                label: text,
                checked: id == value,
                onPressed: () => onChanged(id),
              ),
          ],
        ),
      ),
    );
  }
}
