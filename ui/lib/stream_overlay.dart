part of 'android_screen.dart';

/// Transparent controls above the existing video and input layers.
class StreamOverlayScreen extends StatefulWidget {
  const StreamOverlayScreen({super.key, required this.appearance});

  final AppearanceController appearance;

  @override
  State<StreamOverlayScreen> createState() => _StreamOverlayScreenState();
}

class _StreamOverlayScreenState extends State<StreamOverlayScreen> {
  final _menuArea = GlobalKey();
  final _shortcutsArea = GlobalKey();
  final _minimapArea = GlobalKey();
  final _latched = <int>{};
  final _sheetState = ValueNotifier<_State>(const {});
  NavigatorState? _sheetNavigator;
  late final StreamSubscription<dynamic> _subscription;
  _State _state = {};
  bool _menu = false;
  bool _shortcuts = false;
  bool _backHint = false;
  bool _interactionError = false;
  Timer? _hintTimer;
  bool? _lastModal;
  List<Rect> _lastRects = const [];

  String text(String en, String zh) => widget.appearance.text(en, zh);
  int get _status => _state['status'] as int? ?? 1;
  bool get _connected => _status == 2;
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
    _sheetState.value = state;
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
        await _sheetNavigator?.maybePop();
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
    _sheetState.dispose();
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

  Future<void> _showControls() async {
    if (_menu) return;
    setState(() => _menu = true);
    _publishHitAreas(const [], true);
    ModalRoute<dynamic>? sheetRoute;
    try {
      await showSheet<void>(
        context: context,
        builder: (context) {
          sheetRoute ??= ModalRoute.of(context);
          _sheetNavigator = Navigator.of(context);
          return ValueListenableBuilder<_State>(
            valueListenable: _sheetState,
            builder: (context, state, _) => _StreamOptions(
              appearance: widget.appearance,
              state: state,
              onOptions: _setOptions,
              onClose: () => Navigator.of(context).pop(),
              onResetZoom: () => unawaited(_call('resetZoom')),
              onClearInk: () => unawaited(_call('clearInk')),
              onDisconnect: () => unawaited(_call('disconnect')),
            ),
          );
        },
      );
      await sheetRoute?.completed;
    } finally {
      _sheetNavigator = null;
      if (mounted) setState(() => _menu = false);
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
    _sheetState.value = next;
    setState(() {
      _state = next;
      _shortcuts = next['shortcuts'] == true;
    });
    unawaited(_call('setStreamOptions', patch));
  }

  void _publishHitAreas(List<Rect> rectangles, bool modal) {
    if (_lastModal == modal &&
        _lastRects.length == rectangles.length &&
        Iterable<int>.generate(rectangles.length)
            .every((i) => _lastRects[i] == rectangles[i])) {
      return;
    }
    _lastModal = modal;
    _lastRects = rectangles;
    unawaited(
      _call('streamHitAreas', {
        'modal': modal,
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
    if (_menu) {
      _publishHitAreas(const [], true);
      return;
    }
    final bounds = <Rect>[];
    for (final key in [_menuArea, _shortcutsArea, _minimapArea]) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize)
        bounds.add(box.localToGlobal(Offset.zero) & box.size);
    }
    _publishHitAreas(bounds, false);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureHitAreas());
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
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: TextButton.icon(
                      onPressed: () => unawaited(_showControls()),
                      icon: const GlyphIcon(_settingsGlyph, size: 18),
                      label: Text(text('Controls', '控制')),
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
    final width = _state['estimatedWidth'] ?? '–';
    final height = _state['estimatedHeight'] ?? '–';
    final fps = _state['fps'] ?? '–';
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
              Text(
                '$width × $height · $fps Hz',
                style: AppTextStyle.footnote.of(context, emphasized: true),
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
  const _ChromeGlass({super.key, this.pill = false, required this.child});

  final bool pill;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final useGlass = LiquidGlassScope.of(context);
    final radius = pill ? AppRadius.full : AppRadius.xl;
    final shape = pill ? AppShape.full : AppShape.xl;
    // SurfaceView is a compositor layer outside Flutter. The soft backing
    // maintains readable controls over any source frame without copying video.
    return Surface(
      color: colors.surface.withValues(alpha: useGlass ? .86 : 1),
      shape: shape,
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      child: useGlass
          ? LiquidGlass(
              style: pill
                  ? LiquidGlassStyle.pill(colors)
                  : LiquidGlassStyle.regular(colors),
              borderRadius: radius,
              child: child,
            )
          : child,
    );
  }
}

class _StreamOptions extends StatefulWidget {
  const _StreamOptions({
    required this.appearance,
    required this.state,
    required this.onOptions,
    required this.onClose,
    required this.onResetZoom,
    required this.onClearInk,
    required this.onDisconnect,
  });

  final AppearanceController appearance;
  final _State state;
  final ValueChanged<_State> onOptions;
  final VoidCallback onClose;
  final VoidCallback onResetZoom;
  final VoidCallback onClearInk;
  final VoidCallback onDisconnect;

  @override
  State<_StreamOptions> createState() => _StreamOptionsState();
}

class _StreamOptionsState extends State<_StreamOptions> {
  int? _fps;
  int? _bitrate;

  String text(String en, String zh) => widget.appearance.text(en, zh);

  Widget _switch(String label, String key, {bool fallback = false}) {
    final value = widget.state[key] as bool? ?? fallback;
    void update(bool enabled) => widget.onOptions({key: enabled});
    return DecorationListItem(
      title: Text(label),
      onPressed: () => update(!value),
      trailing: Switch(value: value, onChanged: update, semanticLabel: label),
    );
  }

  Widget _setting(String title, String key, List<(String, String)> choices) =>
      _OptionsRow(
        title: title,
        options: choices,
        value: widget.state[key] as String? ?? choices.first.$1,
        onChanged: (value) => widget.onOptions({key: value}),
      );

  @override
  Widget build(BuildContext context) {
    final currentFps = widget.state['fps'] as int? ?? 60;
    final currentRate = widget.state['bitrateKbps'] as int? ?? -1;
    final maxFps = widget.state['maxFps'] as int? ?? 120;
    final rates = {
      60,
      90,
      120,
      currentFps,
    }.where((rate) => rate <= maxFps).toList()..sort();
    final modified =
        (_fps != null && _fps != currentFps) ||
        (_bitrate != null && _bitrate != currentRate);
    return _PrismPage(
      title: text('Display controls', '副屏控制'),
      compact: context.isInCompactSheet,
      leading: _BarButton(
        label: text('Close', '关闭'),
        glyph: Glyphs.close,
        onPressed: widget.onClose,
      ),
      body: _PageScroll(
        children: [
          generateSection(
            title: text('Stream', '串流'),
            items: [
              _OptionsRow<int>(
                title: text('Refresh rate', '刷新率'),
                options: [for (final rate in rates) (rate, '$rate Hz')],
                value: _fps ?? currentFps,
                onChanged: (value) => setState(() => _fps = value),
              ),
              _OptionsRow<int>(
                title: text('Bitrate', '码率'),
                options: [
                  (-1, text('Auto', '自动')),
                  for (final rate in [15, 25, 35, 50])
                    (rate * 1000, '$rate Mbps'),
                ],
                value: _bitrate ?? currentRate,
                onChanged: (value) => setState(() => _bitrate = value),
              ),
            ],
          ),
          if (modified)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TonalButton(
                  label: text('Apply stream settings', '应用串流设置'),
                  onPressed: () {
                    widget.onOptions({
                      'fps': _fps ?? currentFps,
                      'bitrateKbps': _bitrate ?? currentRate,
                    });
                    setState(() {
                      _fps = null;
                      _bitrate = null;
                    });
                  },
                ),
              ),
            ),
          generateSection(
            title: text('Touch & pen', '触控与笔'),
            items: [
              _setting(text('Touch mode', '触控模式'), 'touchMode', [
                ('ALL_TOUCH', text('All touch', '全部触控')),
                ('PEN_ONLY', text('Pen only', '仅用笔')),
                ('TWO_FINGER_SCROLL', text('Two-finger scroll', '双指滚动')),
              ]),
              _setting(text('Pressure curve', '压力曲线'), 'pressureCurve', [
                ('LINEAR', text('Linear', '线性')),
                ('SOFT', text('Soft', '柔和')),
                ('FIRM', text('Firm', '偏硬')),
                ('HARD', text('Hard', '硬')),
              ]),
              _setting(text('Pen button', '笔身按键'), 'barrelMapping', [
                ('RIGHT_CLICK', text('Right-click', '右键')),
                ('ERASER', text('Eraser', '橡皮擦')),
              ]),
              _setting(text('Local ink', '本地笔迹'), 'inkMode', [
                ('FADE', text('Fade', '渐隐')),
                ('OFF', text('Off', '关闭')),
                ('PERSIST', text('Keep', '保留')),
              ]),
              if (widget.state['inkMode'] == 'PERSIST')
                _ActionRow(
                  title: text('Clear local ink', '清除本地笔迹'),
                  onPressed: widget.onClearInk,
                ),
              _switch(
                text('Pinch to zoom', '双指缩放'),
                'pinchZoom',
                fallback: true,
              ),
            ],
          ),
          generateSection(
            title: text('On-screen tools', '屏幕工具'),
            items: [
              _switch(text('Drawing shortcuts', '绘图快捷键'), 'shortcuts'),
              _switch(text('Zoom map', '缩放导航图'), 'minimap', fallback: true),
              _switch(text('Diagnostics', '诊断信息'), 'diagnostics'),
              _ActionRow(
                title: text('Reset zoom', '重置缩放'),
                onPressed: widget.onResetZoom,
              ),
            ],
          ),
          generateSection(
            items: [
              DecorationListItem(
                title: Builder(
                  builder: (context) => Text(
                    text('Disconnect', '断开连接'),
                    style: TextStyle(color: context.colorScheme.error),
                  ),
                ),
                onPressed: widget.onDisconnect,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
