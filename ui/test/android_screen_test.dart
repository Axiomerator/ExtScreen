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
    themeMode: prefs.dark ? prism.ThemeMode.dark : prism.ThemeMode.light,
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
      expect(prefs.chinese && prefs.dark, isTrue);
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
      final prefs = AppearanceController.inMemory(chinese: true, dark: true);
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

  testWidgets(
    'stream menu preserves panel options and native pointer routing',
    (tester) async {
      tester.view.physicalSize = const Size(620, 350);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <MethodCall>[];
      final state = <Object?, Object?>{
        'status': 2,
        'fps': 120,
        'maxFps': 120,
        'bitrateKbps': -1,
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
      bindings.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'getStreamState':
            return state;
          case 'setStreamOptions':
            state.addAll(call.arguments as Map<Object?, Object?>);
            return state;
        }
        return null;
      });
      final prefs = AppearanceController.inMemory();
      tester.platformDispatcher.defaultRouteNameTestValue = '/stream';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      await tester.pumpWidget(ExtScreenApp(appearance: prefs, stream: true));
      await tester.pumpAndSettle();
      final overlay = tester.element(find.byType(StreamOverlayScreen));
      expect(ModalRoute.of(overlay)?.opaque, isFalse);
      expect(Navigator.of(overlay).canPop(), isFalse);
      expect(
        calls.lastWhere((call) => call.method == 'streamHitAreas').arguments,
        containsPair('modal', false),
      );
      await tester.tap(find.text('Controls'));
      await tester.pumpAndSettle();
      expect(find.text('Display controls'), findsOneWidget);
      expect(
        calls.lastWhere((call) => call.method == 'streamHitAreas').arguments,
        containsPair('modal', true),
      );
      await tester.tap(find.text('Refresh rate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('90 Hz'));

      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Apply stream settings'));

      await tester.tap(find.text('Apply stream settings'));
      await tester.pumpAndSettle();
      expect(
        calls.lastWhere((call) => call.method == 'setStreamOptions').arguments,
        containsPair('fps', 90),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is prism.IconButton && widget.tooltip == 'Close',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        calls.lastWhere((call) => call.method == 'streamHitAreas').arguments,
        containsPair('modal', false),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
