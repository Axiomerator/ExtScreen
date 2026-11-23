import 'package:extscreen/appearance.dart';
import 'package:extscreen/windows_bridge.dart';
import 'package:extscreen/windows_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as p;

class _Host implements HostBridge {
  final calls = <(String, Object?)>[];
  int fps = 120;
  bool connected = true;

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
}
