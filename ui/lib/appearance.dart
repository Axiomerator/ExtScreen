import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

class AppearanceController extends ChangeNotifier {
  AppearanceController._(this._chinese, this._themeMode, {bool persist = true})
    : _persist = persist;

  @visibleForTesting
  AppearanceController.inMemory({
    bool chinese = false,
    prism.ThemeMode themeMode = prism.ThemeMode.system,
  }) : this._(chinese, themeMode, persist: false);

  static const _android = MethodChannel('extscreen/appearance');
  static File get _windows => File(
    '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
    '\\ExtScreen\\appearance.json',
  );

  final bool _persist;
  bool _chinese;
  prism.ThemeMode _themeMode;

  bool get chinese => _chinese;
  prism.ThemeMode get themeMode => _themeMode;

  static Future<AppearanceController> load() async {
    final platform = WidgetsBinding.instance.platformDispatcher;
    Map<Object?, Object?> saved = const {};
    try {
      if (Platform.isAndroid) {
        saved =
            await _android.invokeMapMethod<Object?, Object?>('load') ??
            const {};
      } else if (Platform.isWindows && _windows.existsSync()) {
        final decoded = jsonDecode(_windows.readAsStringSync());
        if (decoded is Map<String, dynamic>) saved = decoded;
      }
    } on MissingPluginException {
      // Flutter widget tests do not run an Android host.
    } on FileSystemException {
      // Use the current platform preferences if the saved file is inaccessible.
    } on FormatException {
      // Recover by overwriting malformed preferences on the next change.
    }
    final language = saved['language'] ?? platform.locale.languageCode;
    return AppearanceController._(language == 'zh', themeModeFrom(saved));
  }

  @visibleForTesting
  static prism.ThemeMode themeModeFrom(Map<Object?, Object?> saved) =>
      switch (saved['themeMode']) {
        'light' => prism.ThemeMode.light,
        'dark' => prism.ThemeMode.dark,
        'system' => prism.ThemeMode.system,
        _ => switch (saved['dark']) {
          true => prism.ThemeMode.dark,
          false => prism.ThemeMode.light,
          _ => prism.ThemeMode.system,
        },
      };

  static Future<void> applyAndroidSystemBars(Brightness brightness) async {
    try {
      await _android.invokeMethod<void>(
        'setEffectiveDark',
        brightness == Brightness.dark,
      );
    } on MissingPluginException {
      // This engine may have no native appearance channel.
    }
  }

  Future<void> setChinese(bool value) async {
    if (_chinese == value) return;
    _chinese = value;
    notifyListeners();
    if (!_persist) return;
    if (Platform.isAndroid) {
      await _android.invokeMethod<void>('setLanguage', value ? 'zh' : 'en');
    } else if (Platform.isWindows) {
      _saveWindows();
    }
  }

  Future<void> setThemeMode(prism.ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    notifyListeners();
    if (!_persist) return;
    if (Platform.isAndroid) {
      await _android.invokeMethod<void>('setThemeMode', value.name);
    } else if (Platform.isWindows) {
      _saveWindows();
    }
  }

  void _saveWindows() {
    final dest = _windows;
    dest.parent.createSync(recursive: true);
    final temporary = File('${dest.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({
        'language': _chinese ? 'zh' : 'en',
        'themeMode': _themeMode.name,
      }),
    );
    temporary.renameSync(dest.path);
  }

  String text(String en, String zh) => _chinese ? zh : en;
}

class ExtScreenUiStrings extends prism.UiLocalizations {
  ExtScreenUiStrings(this.zh);
  final bool zh;
  String text(String english, String chinese) => zh ? chinese : english;

  @override
  String get back => text('Back', '返回');
  @override
  String get cancel => text('Cancel', '取消');
  @override
  String get clearSearch => text('Clear search', '清除搜索');
  @override
  String get close => text('Close', '关闭');
  @override
  String get copy => text('Copy', '复制');
  @override
  String get cut => text('Cut', '剪切');
  @override
  String get dialog => text('Dialog', '对话框');
  @override
  String get hidePassword => text('Hide password', '隐藏密码');
  @override
  String get more => text('More', '更多');
  @override
  String get noSearchResults => text('No search results', '无搜索结果');
  @override
  String get paste => text('Paste', '粘贴');
  @override
  String get reset => text('Reset', '重置');
  @override
  String get select => text('Select', '选择');
  @override
  String get search => text('Search', '搜索');
  @override
  String get selectAll => text('Select all', '全选');
  @override
  String get showLess => text('Show less', '收起');
  @override
  String get showMore => text('Show more', '展开');
  @override
  String get showPassword => text('Show password', '显示密码');
  @override
  String get sort => text('Sort', '排序');
  @override
  String get submit => text('Submit', '提交');
}

class ExtScreenUiDelegate extends LocalizationsDelegate<prism.UiLocalizations> {
  const ExtScreenUiDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'en' || locale.languageCode == 'zh';

  @override
  Future<prism.UiLocalizations> load(Locale locale) =>
      SynchronousFuture(ExtScreenUiStrings(locale.languageCode == 'zh'));

  @override
  bool shouldReload(ExtScreenUiDelegate old) => false;
}
