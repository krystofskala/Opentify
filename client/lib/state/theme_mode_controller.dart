import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Vzhled appky (Systém / Světlý / Tmavý), uložený per zařízení. Výchozí je
/// TMAVÝ -- appka je navržená dark-first a "podle systému" je u webové
/// appky na ploše iPhonu nespolehlivé (bere vzhled ze Safari, ne z telefonu).
///
/// `--dart-define=THEME_MODE=light|dark|system` (kontrolní buildy) vynutí
/// počáteční hodnotu a uložená volba ji pak nepřepíše.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(_forced ?? ThemeMode.dark) {
    if (_forced == null) _load();
  }

  static const _prefKey = 'appearance.theme_mode';
  static const _define = String.fromEnvironment('THEME_MODE');
  static final ThemeMode? _forced = _parse(_define);

  static ThemeMode? _parse(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => null,
      };

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = _parse(prefs.getString(_prefKey));
      if (saved != null && mounted) state = saved;
    } catch (_) {
      // Úložiště nedostupné (soukromý režim) -- zůstane výchozí tmavý.
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (_) {}
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>((ref) => ThemeModeController());
