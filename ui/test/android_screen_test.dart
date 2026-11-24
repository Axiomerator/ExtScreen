import 'package:extscreen/android_screen.dart';
import 'package:extscreen/appearance.dart';
import 'package:extscreen/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

const _channel = MethodChannel('extscreen/android');
const _events = MethodChannel('extscreen/android/events');

Widget _app(AppearanceController prefs, Widget child) => ListenableBuilder(
  listenable: prefs,
  builder: (context, _) => prism.PrismApp(
    theme: prism.ThemeData(
      colorScheme: prism.ColorScheme.fromSeed(
        seedColor: const Color(0xff236dd8),
      ),
    ),
    darkTheme: prism.ThemeData(
      colorScheme: prism.ColorScheme.fromSeed(
        seedColor: const Color(0xff236dd8),
        brightness: Brightness.dark,
      ),
    ),
    themeMode: prefs.themeMode,
    locale: Locale(prefs.chinese ? 'zh' : 'en'),
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: const [
      ExtScreenUiDelegate(),
      GlobalWidgetsLocalizations.delegate,
    ],
    builder: (context, child) => prism.ViewScope(
      size: MediaQuery.sizeOf(context),
      isMobile: MediaQuery.sizeOf(context).width < 600,
      child: child!,
    ),
    home: child,
  ),
);

void main() {
  final bindings = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    bindings.defaultBinaryMessenger.setMockMethodCallHandler(
      _events,
      (_) async => null,
    );
  });

  tearDown(() {
    bindings.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    bindings.defaultBinaryMessenger.setMockMethodCallHandler(_events, null);
  });

  for (final size in [const Size(350, 620), const Size(1100, 720)]) {
    testWidgets('connection flow and appearance at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const host = {
        'host': '192.168.0.10',
        'port': 59100,
        'name': 'DAWN',
        'hostId': 'test',
        'paired': true,
        'usbTether': false,
      };
      final attempts = <MethodCall>[];
      bindings.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        call,
      ) async {
        attempts.add(call);
        if (call.method == 'getConnectionState')
          return {
            'hosts': [host],
            'tetherActive': false,
          };
        return null;
      });
      final prefs = AppearanceController.inMemory();
      await tester.pumpWidget(_app(prefs, AndroidScreen(appearance: prefs)));
      await tester.pumpAndSettle();
      expect(
        find.byType(prism.NavigationDock),
        size.width < 600 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(prism.NavigationSidebar),
        size.width >= 600 ? findsOneWidget : findsNothing,
      );
      final firstSection = find.byType(prism.DecorationListItem).first;
      expect(
        tester.getTopLeft(firstSection).dy,
        greaterThanOrEqualTo(
          tester.getBottomLeft(find.byType(prism.AppBar)).dy,
        ),
      );
      expect(find.text('DAWN'), findsOneWidget);
      await tester.ensureVisible(find.text('DAWN'));
      await tester.tap(find.text('DAWN'));
      await tester.pumpAndSettle();
      expect(
        attempts.lastWhere((call) => call.method == 'connect').arguments,
        containsPair('hostId', 'test'),
      );
      await tester.tap(find.text('Settings').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('简体中文'));
      await tester.pumpAndSettle();
      expect(find.text('外观'), findsOneWidget);
      await tester.tap(find.text('颜色模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(prefs.chinese && prefs.themeMode == prism.ThemeMode.dark, isTrue);
      expect(
        prism.Theme.of(tester.element(find.text('外观'))).colorScheme.brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'PIN required by the host goes through the Prism pairing dialog',
    (tester) async {
      tester.view.physicalSize = const Size(350, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <MethodCall>[];
      bindings.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'getConnectionState') {
          return {
            'pairing': {
              'host': '192.168.0.10',
              'port': 59100,
              'name': 'DAWN',
              'hostId': 'dawn',
            },
          };
        }
        return null;
      });
      final prefs = AppearanceController.inMemory(
        chinese: true,
        themeMode: prism.ThemeMode.dark,
      );
      await tester.pumpWidget(_app(prefs, AndroidScreen(appearance: prefs)));
      await tester.pumpAndSettle();
      expect(find.text('与 DAWN 配对'), findsOneWidget);
      final input = find.byWidgetPredicate(
        (widget) => widget is prism.TextField && widget.obscureText,
      );
      await tester.enterText(input, '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('配对'));
      await tester.pumpAndSettle();
      final request = calls.lastWhere((call) => call.method == 'connect');
      expect(request.arguments, containsPair('hostId', 'dawn'));
      expect(request.arguments, containsPair('pin', '123456'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(350, 620),
    const Size(620, 350),
    const Size(850, 650),
  ]) {
    testWidgets('stream popup preserves native pointer routing at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <MethodCall>[];
      final state = <Object?, Object?>{
        'status': 2,
        'fps': 60,
        'targetFps': 120,
        'maxFps': 120,
        'bitrateKbps': -1,
        'manualBitrateKbps': 0,
        'streamWidth': 2560,
        'streamHeight': 1440,
        'refreshHz': 144,
        'streamBitrateKbps': 20500,
        'orientation': 'landscape',
        'panelWidth': 3200,
        'panelHeight': 2136,
        'peerName': 'DAWN',
        'shortcuts': false,
        'minimap': true,
        'viewport': {
          'scale': 2.0,
          'left': 0.0,
          'top': 0.0,
          'right': 0.5,
          'bottom': 0.5,
        },
      };
      final messenger = bindings.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'getStreamState':
            return state;
          case 'setStreamOptions':
            final patch = call.arguments as Map<Object?, Object?>;
            state.addAll(patch);
            if (patch case {'fps': final fps}) state['targetFps'] = fps;
            return state;
        }
        return null;
      });
      Map<Object?, Object?> hitAreas() =>
          calls.lastWhere((call) => call.method == 'streamHitAreas').arguments
              as Map<Object?, Object?>;
      Future<void> nativeBack({bool settle = true}) async {
        await messenger.handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(
            const MethodCall('dismissStreamMenu'),
          ),
          null,
        );
        if (settle) {
          await tester.pumpAndSettle();
        } else {
          await tester.pump();
        }
      }

      final prefs = AppearanceController.inMemory();
      tester.platformDispatcher.defaultRouteNameTestValue = '/stream';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      await tester.pumpWidget(ExtScreenApp(appearance: prefs, stream: true));
      await tester.pumpAndSettle();
      final overlay = tester.element(find.byType(StreamOverlayScreen));
      expect(ModalRoute.of(overlay)?.opaque, isFalse);
      expect(Navigator.of(overlay).canPop(), isFalse);
      expect(hitAreas(), containsPair('modal', false));
      expect(hitAreas(), containsPair('popupOpen', false));

      await tester.tap(find.text('Controls'));
      await tester.pumpAndSettle();
      expect(find.text('Display controls'), findsOneWidget);
      for (final label in ['2560 × 1440', '144 Hz', 'Landscape', '20.5 Mb/s']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('120 FPS'), findsOneWidget);
      expect(find.text('3200 × 2136'), findsNothing);
      expect(hitAreas(), containsPair('modal', false));
      expect(hitAreas(), containsPair('popupOpen', true));
      final hitRects = (hitAreas()['rects'] as List)
          .cast<Map<Object?, Object?>>();
      final panel = hitRects.last;
      expect(panel['right'], closeTo(size.width - 12, 1));
      expect(panel['left'], greaterThanOrEqualTo(12));
      expect(panel['top'], lessThan(80));
      expect(panel['bottom'], lessThanOrEqualTo(size.height - 12));
      if (size.width >= 700) {
        final limits = tester.getTopLeft(find.text('Stream limits'));
        final tools = tester.getTopLeft(find.text('On-screen tools'));
        expect(tools.dx, greaterThan(limits.dx + 150));
        expect(tools.dy, closeTo(limits.dy, 1));
      }

      await tester.ensureVisible(find.text('Frame rate limit'));
      await tester.tap(find.text('Frame rate limit'));
      await tester.pumpAndSettle();
      final menu = find.byType(prism.PopupMenu);
      expect(menu, findsOneWidget);
      expect(find.text('90 FPS'), findsOneWidget);
      expect(
        tester
            .widget<prism.PopupMenu>(menu)
            .items
            .singleWhere((item) => item.checked == true)
            .label,
        '120 FPS',
      );
      expect(hitAreas(), containsPair('modal', true));
      expect(find.text('Display controls'), findsOneWidget);
      await nativeBack(settle: false);
      expect(hitAreas(), containsPair('modal', true));
      await nativeBack(settle: false);
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.text('Display controls'), findsOneWidget);
      expect(hitAreas(), containsPair('modal', false));
      expect(hitAreas(), containsPair('popupOpen', true));

      await tester.tap(find.text('Frame rate limit'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(hitAreas(), containsPair('modal', false));

      await tester.ensureVisible(find.text('Frame rate limit'));
      await tester.tap(find.text('Frame rate limit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('90 FPS'));
      await tester.pump();
      expect(find.text('Apply stream settings'), findsNothing);
      await tester.pumpAndSettle();
      expect(hitAreas(), containsPair('modal', false));
      expect(calls.where((call) => call.method == 'setStreamOptions'), isEmpty);
      await tester.tap(find.text('Apply stream settings'));
      await tester.pumpAndSettle();
      expect(
        calls.lastWhere((call) => call.method == 'setStreamOptions').arguments,
        {'fps': 90},
      );

      await nativeBack();
      expect(find.text('Display controls'), findsNothing);
      expect(hitAreas(), containsPair('modal', false));
      expect(hitAreas(), containsPair('popupOpen', false));
      expect(tester.takeException(), isNull);
    });
  }
}
