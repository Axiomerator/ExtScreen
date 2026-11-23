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
        themeMode: appearance.dark
            ? prism.ThemeMode.dark
            : prism.ThemeMode.light,
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
            child: navigator!,
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
