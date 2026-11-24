import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'android_screen.dart';
import 'appearance.dart';
import 'windows_screen.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final stream = binding.platformDispatcher.defaultRouteName == '/stream';
  final appearance = await AppearanceController.load();
  runApp(ExtScreenApp(appearance: appearance, stream: stream));
}

class ExtScreenApp extends StatelessWidget {
  const ExtScreenApp({
    super.key,
    required this.appearance,
    required this.stream,
  });

  final AppearanceController appearance;
  final bool stream;

  static prism.ThemeData _theme(Brightness brightness) => prism.ThemeData(
    visualDensity: Platform.isWindows
        ? prism.VisualDensity.compact
        : prism.VisualDensity.standard,
    fontFamilyFallback: Platform.isWindows
        ? const ['Microsoft YaHei UI', 'Microsoft YaHei']
        : null,
    colorScheme: prism.ColorScheme.fromSeed(
      seedColor: const Color(0xFF236DD8),
      brightness: brightness,
      style: prism.ColorStyle.tinted,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, child) => prism.PrismApp(
        title: 'ExtScreen',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: appearance.themeMode,
        manageSystemUiOverlayStyle: !Platform.isAndroid,
        liquidGlass: Platform.isAndroid
            ? prism.LiquidGlassQuality.standard
            : null,
        supportedLocales: const [Locale('en'), Locale('zh')],
        locale: Locale(appearance.chinese ? 'zh' : 'en'),
        localizationsDelegates: const [
          ExtScreenUiDelegate(),
          GlobalWidgetsLocalizations.delegate,
        ],
        builder: (context, navigator) {
          final size = MediaQuery.sizeOf(context);
          return prism.ViewScope(
            size: size,
            isMobile: size.width <= 600,
            child: Platform.isAndroid
                ? _AndroidSystemBars(child: navigator!)
                : navigator!,
          );
        },
        home: stream ? null : child,
        onGenerateRoute: (settings) => settings.name == '/stream'
            ? PageRouteBuilder<void>(
                settings: settings,
                opaque: false,
                pageBuilder: (_, _, _) =>
                    StreamOverlayScreen(appearance: appearance),
              )
            : null,
        debugShowCheckedModeBanner: false,
      ),
      child: stream
          ? null
          : Platform.isWindows
          ? WindowsScreen(appearance: appearance)
          : AndroidScreen(appearance: appearance),
    );
  }
}

class _AndroidSystemBars extends StatefulWidget {
  const _AndroidSystemBars({required this.child});

  final Widget child;

  @override
  State<_AndroidSystemBars> createState() => _AndroidSystemBarsState();
}

class _AndroidSystemBarsState extends State<_AndroidSystemBars> {
  Brightness? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = prism.Theme.brightnessOf(context);
    if (_applied == brightness) return;
    _applied = brightness;
    unawaited(AppearanceController.applyAndroidSystemBars(brightness));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
