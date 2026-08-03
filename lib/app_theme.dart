import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pasture / farm green — Material 3 seed (replaces default purple).
const Color kPastureSeed = Color(0xFF2E7D32);

abstract final class AppTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kPastureSeed,
          brightness: Brightness.light,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kPastureSeed,
          brightness: Brightness.dark,
        ),
      );
}

class ThemeController extends ChangeNotifier {
  static const prefsKey = 'themeMode';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _mode = fromPrefs(p.getString(prefsKey));
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(prefsKey, toPrefs(mode));
  }

  static String toPrefs(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  static ThemeMode fromPrefs(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String label(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      };
}
