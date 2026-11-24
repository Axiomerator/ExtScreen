part of 'android_screen.dart';

/// Transparent controls above the existing video and input layers.
class StreamOverlayScreen extends StatefulWidget {
  const StreamOverlayScreen({super.key, required this.appearance});

  final AppearanceController appearance;

  @override
  State<StreamOverlayScreen> createState() => _StreamOverlayScreenState();
}

class _StreamOverlayScreenState extends State<StreamOverlayScreen>
    with SingleTickerProviderStateMixin {
  static const _popupDuration = Duration(milliseconds: 180);

  final _popupKey = GlobalKey();
  late final _popupAnimation = AnimationController(
    vsync: this,
    duration: _popupDuration,
  )..addStatusListener(_popupStatusChanged);

  final _menuArea = GlobalKey();
  final _shortcutsArea = GlobalKey();
  final _minimapArea = GlobalKey();
  final _latched = <int>{};
  late final StreamSubscription<dynamic> _subscription;
  _State _state = {};
  bool _menu = false;
  bool _shortcuts = false;
  bool _backHint = false;
  bool _interactionError = false;
  Timer? _hintTimer;
  ModalRoute<dynamic>? _choiceRoute;
  bool? _lastModal;
  bool? _lastPopupOpen;
  List<Rect> _lastRects = const [];

  String text(String en, String zh) => widget.appearance.text(en, zh);
  int get _status => _state['status'] as int? ?? 1;
  bool get _connected => _status == 2;
  bool get _popupVisible => _menu || !_popupAnimation.isDismissed;
  String get _peer {
    final name = _state['peerName'] as String? ?? 'ExtScreen';
    return _state['directUsb'] == true &&
            const {
              'USB',
              'USB cable',
              'Direct USB (Plug & Play)',
            }.contains(name)
        ? text('Direct USB', 'USB 直连')
        : name;
  }

  bool _option(String name, [bool fallback = false]) =>
      _state[name] as bool? ?? fallback;

  @override
  void initState() {
    super.initState();
    _android.setMethodCallHandler(_onNativeCall);
    _subscription = _events.receiveBroadcastStream().listen(
      (event) => _receive(event as _State),
      onError: (Object error) => _reportUnavailable(),
    );
    unawaited(_readStreamState());
  }

  Future<void> _readStreamState() async {
    try {
      final state = await _android.invokeMapMethod<Object?, Object?>(
        'getStreamState',
      );
      if (state != null && _state.isEmpty) _receive(state);
    } on PlatformException {
      _reportUnavailable();
    }
  }

  void _receive(_State state) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _shortcuts = state['shortcuts'] == true;
      _latched
        ..clear()
        ..addAll(
          (state['heldKeys'] as List<Object?>? ?? const []).whereType<int>(),
        );
    });
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (!mounted) return null;
    switch (call.method) {
      case 'dismissStreamMenu':
        final choice = _choiceRoute;
        if (choice != null) {
          if (choice.isCurrent) choice.navigator?.pop();
        } else if (_menu) {
          _setPopup(false);
        }
      case 'backHint':
        _hintTimer?.cancel();
        setState(() => _backHint = true);
        _hintTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _backHint = false);
        });
    }
    return null;
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    unawaited(_subscription.cancel());
    _android.setMethodCallHandler(null);
    _popupAnimation.dispose();
    super.dispose();
  }

  void _reportUnavailable() {
    if (mounted && !_interactionError) setState(() => _interactionError = true);
  }

  Future<void> _call(String method, [_State? options]) async {
    try {
      final state = await _android.invokeMethod<Object?>(method, options);
      if (state is _State) _receive(state);
    } on PlatformException {
      _reportUnavailable();
    }
  }

  void _popupStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted && !_menu) {
      setState(() {});
    }
  }

  void _setPopup(bool open) {
    if (open == _menu) return;
    _popupAnimation.duration = context.motionDuration(_popupDuration);
    setState(() => _menu = open);
    if (open) {
      _popupAnimation.forward();
    } else {
      _popupAnimation.reverse();
    }
  }

  void _sendKey(int key, {int action = 2, int modifiers = 0}) {
    unawaited(
      _call('sendKey', {'code': key, 'action': action, 'modifiers': modifiers}),
    );
  }

  void _toggleLatch(int key) {
    final active = _latched.contains(key);
    setState(() => active ? _latched.remove(key) : _latched.add(key));
    _sendKey(key, action: active ? 1 : 0);
  }

  void _setOptions(_State patch) {
    final next = {..._state, ...patch};
    setState(() {
      _state = next;
      _shortcuts = next['shortcuts'] == true;
    });
    unawaited(_call('setStreamOptions', patch));
  }

  void _watchChoiceRoute(ModalRoute<dynamic> route) {
    if (identical(_choiceRoute, route)) return;
    _choiceRoute = route;
    _scheduleMeasure();
    unawaited(
      route.completed.then((_) {
        if (!mounted || !identical(_choiceRoute, route)) return;
        _choiceRoute = null;
        _measureHitAreas();
      }),
    );
  }

  void _publishHitAreas(List<Rect> rectangles, bool popupOpen) {
    // Prism owns menu taps and its tap-away barrier through the return morph.
    // The parent control panel otherwise only owns its measured hit areas.
    final modal = _choiceRoute != null;
    if (_lastModal == modal &&
        _lastPopupOpen == popupOpen &&
        _lastRects.length == rectangles.length &&
        Iterable<int>.generate(rectangles.length)
            .every((i) => _lastRects[i] == rectangles[i])) {
      return;
    }
    _lastModal = modal;
    _lastPopupOpen = popupOpen;
    _lastRects = rectangles;
    unawaited(
      _call('streamHitAreas', {
        'modal': modal,
        'popupOpen': popupOpen,
        'rects': [
          for (final rect in rectangles)
            {
              'left': rect.left,
              'top': rect.top,
              'right': rect.right,
              'bottom': rect.bottom,
            },
        ],
      }),
    );
  }

  void _measureHitAreas() {
    if (!mounted) return;
    final bounds = <Rect>[];
    for (final key in [_menuArea, _shortcutsArea, _minimapArea, _popupKey]) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && !box.size.isEmpty) {
        bounds.add(box.localToGlobal(Offset.zero) & box.size);
      }
    }
    _publishHitAreas(bounds, _popupVisible);
  }

  Widget _popup() {
    return Positioned.fill(
      top: 56,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth >= 700 ? 572.0 : 380.0;
          final width = constraints.maxWidth.clamp(0.0, maxWidth).toDouble();
          return Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: width,
              child: ExcludeFocus(
                excluding: !_menu,
                child: IgnorePointer(
                  ignoring: !_menu,
                  child: FadeTransition(
                    opacity: _popupAnimation,
                    child: _ChromeGlass(
                      popup: true,
                      child: _StreamOptions(
                        key: _popupKey,
                        appearance: widget.appearance,
                        state: _state,
                        onOptions: _setOptions,
                        onClose: () => _setPopup(false),
                        onResetZoom: () => unawaited(_call('resetZoom')),
                        onClearInk: () => unawaited(_call('clearInk')),
                        onDisconnect: () => unawaited(_call('disconnect')),
                        onLayout: _scheduleMeasure,
                        onChoiceRoute: _watchChoiceRoute,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _scheduleMeasure() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureHitAreas());

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    final viewport = _state['viewport'] as _State?;
    final scale = (viewport?['scale'] as num?)?.toDouble() ?? 1;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!_connected)
          Surface(
            color: context.colorScheme.surface,
            child: Center(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      if (_status <= 1) const ActivityIndicator(),
                      Text(
                        _peer,
                        textAlign: TextAlign.center,
                        style: AppTextStyle.title2.of(context),
                      ),
                      Semantics(
                        liveRegion: true,
                        child: Text(_statusText, textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        SafeArea(
          minimum: const EdgeInsets.all(12),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                right: 0,
                child: _ChromeGlass(
                  key: _menuArea,
                  pill: true,
                  child: Semantics(
                    expanded: _menu,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: TextButton.icon(
                        onPressed: () => _setPopup(!_menu),
                        icon: const GlyphIcon(_settingsGlyph, size: 18),
                        label: Text(text('Controls', '控制')),
                      ),
                    ),
                  ),
                ),
              ),
              if (_connected && _shortcuts)
                Positioned.fill(
                  top: _option('diagnostics') ? 132 : 0,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: (constraints.maxHeight - 12)
                              .clamp(0.0, double.infinity)
                              .toDouble(),
                          maxWidth: 164,
                        ),
                        child: _shortcutDock(),
                      ),
                    ),
                  ),
                ),
              if (_connected && _option('diagnostics'))
                Positioned(
                  left: 0,
                  top: 0,
                  right: 128,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _diagnostics(),
                  ),
                ),
              if (_connected &&
                  _option('minimap', true) &&
                  scale > 1.01 &&
                  viewport != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _minimap(viewport, scale),
                ),
              if (_popupVisible) _popup(),
              if (_backHint || _interactionError)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: IgnorePointer(
                    child: _ChromeGlass(
                      pill: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _backHint
                                ? text(
                                    'Go back again to disconnect',
                                    '再次返回以断开连接',
                                  )
                                : text(
                                    'Could not complete the action',
                                    '未能完成该操作',
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String get _statusText => switch (_status) {
    0 => text('Waiting to reconnect…', '正在等待重新连接…'),
    3 => text('Pairing required', '需要配对'),
    4 => text('Pairing failed', '配对失败'),
    5 => text('Display connected to another device', '副屏已连接到另一台设备'),
    _ => text('Connecting…', '正在连接…'),
  };

  Widget _shortcutDock() {
    final keys = [
      (text('Undo', '撤销'), 0x5A, 1, false),
      (text('Redo', '重做'), 0x59, 1, false),
      ('Ctrl', 0x11, 0, true),
      ('Shift', 0x10, 0, true),
      ('Alt', 0x12, 0, true),
      (text('Space', '空格'), 0x20, 0, true),
      (text('Smaller brush', '缩小笔刷'), 0xDB, 0, false),
      (text('Larger brush', '放大笔刷'), 0xDD, 0, false),
      (text('Fit canvas', '适合画布'), 0x30, 1, false),
      (text('Toggle panels', '切换面板'), 0x09, 0, false),
    ];
    return _ChromeGlass(
      key: _shortcutsArea,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 2,
          children: [
            for (final (label, key, modifiers, latch) in keys)
              Semantics(
                toggled: latch ? _latched.contains(key) : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: _latched.contains(key)
                      ? FilledButton(
                          onPressed: () => _toggleLatch(key),
                          child: Text(label),
                        )
                      : TextButton(
                          onPressed: () => latch
                              ? _toggleLatch(key)
                              : _sendKey(key, modifiers: modifiers),
                          child: Text(label),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _minimap(_State viewport, double scale) {
    return _ChromeGlass(
      key: _minimapArea,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, maxWidth: 200),
        child: TextButton(
          onPressed: () => unawaited(_call('resetZoom')),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              SizedBox(
                width: 26,
                height: 16,
                child: CustomPaint(
                  painter: _ViewportPainter(
                    viewport,
                    context.colorScheme.onSurface,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  text(
                    'Reset zoom · ${scale.toStringAsFixed(1)}×',
                    '重置缩放 · ${scale.toStringAsFixed(1)}×',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _diagnostics() {
    final rttUs = _state['rttUs'] as num? ?? 0;
    final rtt = rttUs > 0 ? '${(rttUs / 1000).toStringAsFixed(1)} ms' : '–';
    final packets = _state['packetsSent'] ?? 0;
    final pen = _state['diagnosticData'] as _State?;
    final tool = switch (pen?['toolType']) {
      1 => text('Touch', '触控'),
      2 => text('Pen', '笔'),
      3 => text('Mouse', '鼠标'),
      4 => text('Eraser', '橡皮擦'),
      _ => text('Idle', '空闲'),
    };
    return IgnorePointer(
      child: _ChromeGlass(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              _StreamMetrics(
                state: _state,
                appearance: widget.appearance,
                compact: true,
              ),
              Text(
                text(
                  'RTT $rtt · $packets input events',
                  '往返 $rtt · $packets 个输入事件',
                ),
                style: AppTextStyle.footnote.of(context),
              ),
              if (pen case {'pressure': final num pressure})
                Text(
                  text(
                    '$tool · Pressure ${pressure.toStringAsFixed(2)} · ${pen['sampleRateHz'] ?? '–'} Hz',
                    '$tool · 笔压 ${pressure.toStringAsFixed(2)} · ${pen['sampleRateHz'] ?? '–'} Hz',
                  ),
                  style: AppTextStyle.footnote.of(context),
                ),
              if (pen case {'tiltX': final num tiltX, 'tiltY': final num tiltY})
                Text(
                  text(
                    'Tilt ${tiltX.round()}° / ${tiltY.round()}°',
                    '倾角 ${tiltX.round()}° / ${tiltY.round()}°',
                  ),
                  style: AppTextStyle.footnote.of(context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewportPainter extends CustomPainter {
  const _ViewportPainter(this.viewport, this.color);

  final _State viewport;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    double fraction(String key, double fallback) =>
        ((viewport[key] as num?)?.toDouble() ?? fallback)
            .clamp(0.0, 1.0)
            .toDouble();
    final paint = Paint()..color = color;
    final bounds = (Offset.zero & size).deflate(1);
    final visible = Rect.fromLTRB(
      bounds.left + bounds.width * fraction('left', 0),
      bounds.top + bounds.height * fraction('top', 0),
      bounds.left + bounds.width * fraction('right', 1),
      bounds.top + bounds.height * fraction('bottom', 1),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(2)),
      paint..style = PaintingStyle.stroke,
    );
    canvas.drawRect(visible, paint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _ViewportPainter oldDelegate) =>
      viewport != oldDelegate.viewport || color != oldDelegate.color;
}

class _ChromeGlass extends StatelessWidget {
  const _ChromeGlass({
    super.key,
    this.pill = false,
    this.popup = false,
    required this.child,
  });

  final bool pill;
  final bool popup;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final useGlass = LiquidGlassScope.of(context);
    final radius = pill ? AppRadius.full : AppRadius.xl;
    final fill = popup
        ? SurfaceLevel.floatingOf(colors).colorOf(colors)
        : colors.surface;
    final shape = pill ? AppShape.full : AppShape.xl;
    // SurfaceView is a compositor layer outside Flutter. The soft backing
    // maintains readable controls over any source frame without copying video.
    return Surface(
      color: fill.withValues(alpha: useGlass ? (popup ? .78 : .86) : 1),
      shape: shape,
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      child: useGlass
          ? LiquidGlass(
              style: pill
                  ? LiquidGlassStyle.pill(colors)
                  : popup
                  ? LiquidGlassStyle.menu(colors)
                  : LiquidGlassStyle.regular(colors),
              borderRadius: radius,
              child: child,
            )
          : child,
    );
  }
}

class _StreamMetrics extends StatelessWidget {
  const _StreamMetrics({
    required this.state,
    required this.appearance,
    this.compact = false,
  });

  final _State state;
  final AppearanceController appearance;
  final bool compact;

  String text(String en, String zh) => appearance.text(en, zh);

  String _frequency(String key) {
    final value = state[key];
    if (value is! num || value <= 0) return '—';
    final label = value % 1 == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
    return '$label Hz';
  }

  String _resolution(String width, String height) {
    final w = state[width];
    final h = state[height];
    return w is int && h is int && w > 0 && h > 0 ? '$w × $h' : '—';
  }

  String _bitrate() {
    final value = state['streamBitrateKbps'];
    return value is num && value > 0
        ? '${(value / 1000).toStringAsFixed(1)} Mb/s'
        : '—';
  }

  @override
  Widget build(BuildContext context) {
    final resolution = _resolution('streamWidth', 'streamHeight');
    final refresh = _frequency('refreshHz');
    final bitrate = _bitrate();
    final orientation = switch (state['orientation']) {
      'portrait' => text('Portrait', '竖屏'),
      'landscape' => text('Landscape', '横屏'),
      _ => '—',
    };
    final style = AppTextStyle.footnote.of(context);
    if (compact) {
      final panel = _resolution('panelWidth', 'panelHeight');
      final panelHz = _frequency('panelRefreshHz');
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text('$resolution · $refresh · $bitrate', style: style),
          if (panel != '—' || panelHz != '—')
            Text(
              text('Device panel $panel · $panelHz', '本机面板 $panel · $panelHz'),
              style: style,
            ),
        ],
      );
    }
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (label, value) in [
          (text('Resolution', '分辨率'), resolution),
          (text('Display refresh', '实际刷新率'), refresh),
          (text('Orientation', '方向'), orientation),
          (text('Stream bitrate', '实际码率'), bitrate),
        ])
          Semantics(
            label: '$label $value',
            excludeSemantics: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  label,
                  style: style.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

enum _StreamField { fps, bitrate, touch, pressure, barrel, ink }

class _StreamOptions extends StatefulWidget {
  const _StreamOptions({
    super.key,
    required this.appearance,
    required this.state,
    required this.onOptions,
    required this.onClose,
    required this.onResetZoom,
    required this.onClearInk,
    required this.onDisconnect,
    required this.onLayout,
    required this.onChoiceRoute,
  });

  final AppearanceController appearance;
  final _State state;
  final ValueChanged<_State> onOptions;
  final VoidCallback onClose;
  final VoidCallback onResetZoom;
  final VoidCallback onClearInk;
  final VoidCallback onDisconnect;
  final VoidCallback onLayout;
  final ValueChanged<ModalRoute<dynamic>> onChoiceRoute;

  @override
  State<_StreamOptions> createState() => _StreamOptionsState();
}

typedef _ChoiceData = ({
  String title,
  List<(Object, String)> options,
  Object value,
  ValueChanged<Object> select,
});

class _StreamOptionsState extends State<_StreamOptions> {
  static const _touchHeight = 48.0;
  static const _padding = EdgeInsets.symmetric(horizontal: 12);

  int? _fps;
  int? _bitrate;

  String text(String en, String zh) => widget.appearance.text(en, zh);

  int get _currentFps =>
      widget.state['targetFps'] as int? ?? widget.state['fps'] as int? ?? 60;

  int get _currentBitrate => switch (widget.state['manualBitrateKbps']) {
    0 => -1,
    final int kbps => kbps,
    _ => widget.state['bitrateKbps'] as int? ?? -1,
  };

  bool get _hasChanges =>
      (_fps != null && _fps != _currentFps) ||
      (_bitrate != null && _bitrate != _currentBitrate);

  String _fpsLabel(int fps) => fps == 0 ? text('Auto', '自动') : '$fps FPS';

  String _rateLabel(int kbps) => kbps < 0
      ? text('Auto', '自动')
      : '${(kbps / 1000).toStringAsFixed(kbps % 1000 == 0 ? 0 : 1)} Mb/s';

  _ChoiceData _setting(
    String title,
    String key,
    List<(String, String)> options,
  ) => (
    title: title,
    options: options,
    value: widget.state[key] as String? ?? options.first.$1,
    select: (value) => widget.onOptions({key: value}),
  );

  _ChoiceData _data(_StreamField field) {
    return switch (field) {
      _StreamField.fps => (
        title: text('Frame rate limit', '帧率上限'),
        options: [
          for (final value
              in ({60, 90, 120, _currentFps}
                  .where(
                    (fps) =>
                        fps == _currentFps ||
                        fps <= (widget.state['maxFps'] as int? ?? 120),
                  )
                  .toList()
                ..sort()))
            (value, _fpsLabel(value)),
        ],
        value: _fps ?? _currentFps,
        select: (value) => setState(() => _fps = value as int),
      ),
      _StreamField.bitrate => (
        title: text('Bitrate limit', '码率上限'),
        options: [
          for (final value in ({
            -1,
            15000,
            25000,
            35000,
            50000,
            _currentBitrate,
          }.toList()..sort()))
            (value, _rateLabel(value)),
        ],
        value: _bitrate ?? _currentBitrate,
        select: (value) => setState(() => _bitrate = value as int),
      ),
      _StreamField.touch => _setting(text('Touch mode', '触控模式'), 'touchMode', [
        ('ALL_TOUCH', text('All touch', '全部触控')),
        ('PEN_ONLY', text('Pen only', '仅用笔')),
        ('TWO_FINGER_SCROLL', text('Two-finger scroll', '双指滚动')),
      ]),
      _StreamField.pressure => _setting(
        text('Pressure curve', '压力曲线'),
        'pressureCurve',
        [
          ('LINEAR', text('Linear', '线性')),
          ('SOFT', text('Soft', '柔和')),
          ('FIRM', text('Firm', '偏硬')),
          ('HARD', text('Hard', '硬')),
        ],
      ),
      _StreamField.barrel => _setting(
        text('Pen button', '笔身按键'),
        'barrelMapping',
        [
          ('RIGHT_CLICK', text('Right-click', '右键')),
          ('ERASER', text('Eraser', '橡皮擦')),
        ],
      ),
      _StreamField.ink => _setting(text('Local ink', '本地笔迹'), 'inkMode', [
        ('FADE', text('Fade', '渐隐')),
        ('OFF', text('Off', '关闭')),
        ('PERSIST', text('Keep', '保留')),
      ]),
    };
  }

  Widget _row(String title, {Widget? trailing, VoidCallback? onPressed}) =>
      DecorationListItem(
        minHeight: _touchHeight,
        contentPadding: _padding,
        title: Text(title),
        trailing: trailing,
        onPressed: onPressed,
      );

  Widget _switch(String label, String key, {bool fallback = false}) {
    final value = widget.state[key] as bool? ?? fallback;
    void update(bool enabled) => widget.onOptions({key: enabled});
    return _row(
      label,
      onPressed: () => update(!value),
      trailing: Switch(value: value, onChanged: update, semanticLabel: label),
    );
  }

  Widget _selectField(_StreamField field) {
    final choice = _data(field);
    final index = choice.options.indexWhere(
      (entry) => entry.$1 == choice.value,
    );
    final value = choice.options[index < 0 ? 0 : index].$2;
    PopupOpen? open;
    return _row(
      choice.title,
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
                    constraints: const BoxConstraints(maxWidth: 108),
                    child: PopupValueText(
                      value,
                      alignment: AlignmentDirectional.centerEnd,
                    ),
                  ),
                ),
                const GlyphIcon(Glyphs.picker, size: 16),
              ],
            ),
          );
        },
        popupBuilder: (context) {
          widget.onChoiceRoute(ModalRoute.of(context)!);
          return PopupMenu(
            items: [
              for (final (id, label) in choice.options)
                PopupMenuItem(
                  label: label,
                  checked: id == choice.value,
                  onPressed: () {
                    if (mounted) choice.select(id);
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _group(String title, List<Widget> children) => Column(
    children: [
      ListHeader(
        title: title,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      ),
      generateGroup(children),
    ],
  );

  Widget _settings(BuildContext context) {
    final output = _group(text('Stream limits', '串流限制'), [
      _selectField(_StreamField.fps),
      _selectField(_StreamField.bitrate),
    ]);
    final input = _group(text('Touch & pen', '触控与笔'), [
      _selectField(_StreamField.touch),
      _selectField(_StreamField.pressure),
      _selectField(_StreamField.barrel),
      _selectField(_StreamField.ink),
      if (widget.state['inkMode'] == 'PERSIST')
        _row(text('Clear local ink', '清除本地笔迹'), onPressed: widget.onClearInk),
    ]);
    final tools = _group(text('On-screen tools', '屏幕工具'), [
      _switch(text('Pinch to zoom', '双指缩放'), 'pinchZoom', fallback: true),
      _switch(text('Zoom map', '缩放导航图'), 'minimap', fallback: true),
      _switch(text('Drawing shortcuts', '绘图快捷键'), 'shortcuts'),
      _switch(text('Diagnostics', '诊断信息'), 'diagnostics'),
      _row(text('Reset zoom', '重置缩放'), onPressed: widget.onResetZoom),
    ]);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 492) {
          return Column(spacing: 10, children: [output, input, tools]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Expanded(child: Column(spacing: 10, children: [output, input])),
            Expanded(child: tools),
          ],
        );
      },
    );
  }

  void _apply() {
    widget.onOptions({
      if (_fps case final fps? when fps != _currentFps) 'fps': fps,
      if (_bitrate case final bitrate? when bitrate != _currentBitrate)
        'bitrateKbps': bitrate,
    });
    setState(() {
      _fps = null;
      _bitrate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    widget.onLayout();
    return SurfaceScope(
      level: SurfaceLevel.floatingOf(context.colorScheme),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      text('Display controls', '副屏控制'),
                      style: AppTextStyle.headline.of(context),
                    ),
                  ),
                ),
                _BarButton(
                  label: text('Close', '关闭'),
                  glyph: Glyphs.close,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                    child: _StreamMetrics(
                      state: widget.state,
                      appearance: widget.appearance,
                    ),
                  ),
                  _settings(context),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 4,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _touchHeight),
                  child: TextButton(
                    onPressed: widget.onDisconnect,
                    child: Text(
                      text('Disconnect', '断开连接'),
                      style: TextStyle(color: context.colorScheme.error),
                    ),
                  ),
                ),
                if (_hasChanges)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: _touchHeight),
                    child: FilledButton(
                      onPressed: _apply,
                      child: Text(text('Apply stream settings', '应用串流设置')),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
