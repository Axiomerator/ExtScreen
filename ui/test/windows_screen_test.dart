import 'package:extscreen/appearance.dart';
import 'package:extscreen/windows_bridge.dart';
import 'package:extscreen/windows_screen.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as p;

class _Host implements HostBridge {
  final calls = <(String, Object?)>[];
  int fps = 120;
  bool connected = true;
  Map<String, dynamic>? driver;

  @override
  Future<void> ensureRunning() async {}

  @override
  void hideDashboard() {}

  @override
  void setDashboardDark(bool dark) {}

  @override
  Future<Map<String, dynamic>> request(String command, [Object? value]) async {
    calls.add((command, value));
    if (command == 'set_fps') fps = value as int;
    if (command == 'install_display_driver')
      driver?['operation'] = 'installing';
    if (command == 'uninstall_display_driver')
      driver?['operation'] = 'uninstalling';
    return {
      'ok': true,
      if (command == 'status')
        'status': {
          'connected': connected,
          'device_name': 'Tablet',
          'link': 'usb',
          'width': 3200,
          'height': 2136,
          'refresh_hz': 120,
          'fps': fps,
          'bitrate_kbps': 29000,
          'manual_bitrate_kbps': 0,
          'codec': 'HEVC',
          'pin': '123456',
          'port': 59100,
          'paired_devices': ['Tablet'],
          if (driver != null) 'display_driver': {...driver!},
        },
    };
  }
}

Widget _app(AppearanceController appearance, _Host host) => p.PrismApp(
  theme: p.ThemeData(visualDensity: p.VisualDensity.compact),
  locale: Locale(appearance.chinese ? 'zh' : 'en'),
  supportedLocales: const [Locale('en'), Locale('zh')],
  localizationsDelegates: const [
    ExtScreenUiDelegate(),
    GlobalWidgetsLocalizations.delegate,
  ],
  builder: (context, child) {
    final size = MediaQuery.sizeOf(context);
    return p.ViewScope(size: size, isMobile: size.width <= 600, child: child!);
  },
  home: WindowsScreen(appearance: appearance, host: host),
);

void main() {
  testWidgets('Windows tracks window width with a dock and two sidebar modes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 640);
    addTearDown(tester.view.reset);
    final appearance = AppearanceController.inMemory();
    final host = _Host();
    await tester.pumpWidget(_app(appearance, host));
    await tester.pumpAndSettle();

    expect(find.byType(p.NavigationDock), findsOneWidget);
    expect(find.byType(p.NavigationSidebar), findsNothing);
    expect(find.text('Display connected'), findsOneWidget);
    expect(tester.takeException(), isNull);

    host.connected = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Pairing')).dy,
      lessThan(tester.getTopLeft(find.text('Stream parameters')).dy),
    );

    host.connected = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(760, 680);
    await tester.pumpAndSettle();
    expect(find.byType(p.NavigationDock), findsNothing);
    expect(
      tester
          .widget<p.NavigationSidebar>(find.byType(p.NavigationSidebar))
          .expanded,
      isFalse,
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1080, 720);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<p.NavigationSidebar>(find.byType(p.NavigationSidebar))
          .expanded,
      isTrue,
    );
    final session = tester.getTopLeft(find.text('Current session'));
    final pairing = tester.getTopLeft(find.text('Pairing'));
    expect(session.dx, lessThan(pairing.dx));
    expect(session.dy, closeTo(pairing.dy, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows grouped rows cover fractional-pixel joins', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(1350, 900);
    addTearDown(tester.view.reset);

    final boundary = GlobalKey();
    final appearance = AppearanceController.inMemory();
    final host = _Host();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: Transform.translate(
          offset: const Offset(0, 0.25),
          child: _app(appearance, host),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('Frame rate limit'),
      matching: find.byType(p.DecorationListItem),
    );
    final context = tester.element(row);
    final fill = p.SurfaceScope.of(context).next
        .colorOf(p.Theme.of(context).colorScheme);
    final bounds = tester.getRect(row);
    final result = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final scale = tester.view.devicePixelRatio;
      final image = await render.toImage(pixelRatio: scale);
      try {
        final pixels = (await image.toByteData())!;
        final x = ((bounds.left + 8) * scale).round();
        final join = (bounds.bottom * scale).round();
        return [
          for (var y = join - 3; y <= join + 3; y++)
            pixels.getUint8((y * image.width + x) * 4),
        ];
      } finally {
        image.dispose();
      }
    });

    expect(result, everyElement((fill.toARGB32() >> 16) & 0xff));
  });

  testWidgets('Windows grouped choice rows send the same host commands', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1080, 720);
    addTearDown(tester.view.reset);
    final appearance = AppearanceController.inMemory();
    final host = _Host();
    await tester.pumpWidget(_app(appearance, host));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Frame rate limit'));
    await tester.pumpAndSettle();
    expect(find.byType(p.PopupMenu), findsOneWidget);
    await tester.tap(find.text('90 Hz'));
    await tester.pumpAndSettle();
    expect(host.calls, contains(('set_fps', 90)));

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(appearance.dark, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'driver installation reports activity and restart from the host',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = _Host()
        ..connected = false
        ..driver = {'state': 'missing', 'bundle_available': true};
      await tester.pumpWidget(_app(AppearanceController.inMemory(), host));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Driver settings'));
      await tester.pumpAndSettle();
      expect(find.text('Not installed'), findsOneWidget);
      await tester.tap(find.text('Install driver'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(host.calls, contains(('install_display_driver', null)));
      expect(find.text('Installing driver…'), findsOneWidget);
      final installingAction = tester.widget<p.DecorationListItem>(
        find.ancestor(
          of: find.text('Install driver'),
          matching: find.byType(p.DecorationListItem),
        ),
      );
      expect(installingAction.onPressed, isNull);

      host.driver = {
        'state': 'ready',
        'bundle_available': true,
        'restart_required': true,
      };
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Restart required'), findsOneWidget);
      expect(
        find.text('Restart Windows to complete the change.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mirroring is identified and removing the driver requires confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = _Host()
        ..driver = {
          'state': 'unavailable',
          'bundle_available': true,
          'stream_mode': 'fallback',
        };
      await tester.pumpWidget(_app(AppearanceController.inMemory(), host));
      await tester.pumpAndSettle();
      expect(find.text('Mirroring the primary display'), findsOneWidget);
      expect(find.text('Primary display'), findsOneWidget);
      expect(find.text('Virtual display'), findsNothing);
      await tester.tap(find.text('Driver settings'));
      await tester.pumpAndSettle();
      final connectedAction = tester.widget<p.DecorationListItem>(
        find.ancestor(
          of: find.text('Uninstall driver'),
          matching: find.byType(p.DecorationListItem),
        ),
      );
      expect(connectedAction.onPressed, isNull);

      host.connected = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uninstall driver'));
      await tester.pumpAndSettle();
      expect(find.text('Uninstall the display driver?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains(('uninstall_display_driver', null))));
      await tester.tap(find.text('Uninstall driver'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uninstall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(host.calls, contains(('uninstall_display_driver', null)));
      expect(find.text('Uninstalling driver…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
