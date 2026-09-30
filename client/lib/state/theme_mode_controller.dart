import 'dart:async';

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

/// Jas systému pro "Systém" -- ale ustálený. Webová appka na ploše iPhonu
/// po návratu z jiné appky na okamžik hlásí světlý režim a appka na vteřinu
/// problikla světle (živě nahlášeno). Změna se proto přijme, až když trvá
/// ~0,7 s, a hned po návratu do appky (1,5 s) se krátké změny ignorují.
class StableBrightnessController extends StateNotifier<Brightness> with WidgetsBindingObserver {
  StableBrightnessController() : super(WidgetsBinding.instance.platformDispatcher.platformBrightness) {
    WidgetsBinding.instance.addObserver(this);
  }

  Timer? _check;
  DateTime _resumedAt = DateTime.fromMillisecondsSinceEpoch(0);

  Brightness get _platform => WidgetsBinding.instance.platformDispatcher.platformBrightness;

  void _schedule(Duration after) {
    _check?.cancel();
    _check = Timer(after, () {
      if (mounted && _platform != state) state = _platform;
    });
  }

  @override
  void didChangePlatformBrightness() {
    final sinceResume = DateTime.now().difference(_resumedAt);
    const settle = Duration(milliseconds: 1500);
    _schedule(sinceResume < settle ? settle - sinceResume + const Duration(milliseconds: 700) : const Duration(milliseconds: 700));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _resumedAt = DateTime.now();
  }

  @override
  void dispose() {
    _check?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final stableBrightnessProvider =
    StateNotifierProvider<StableBrightnessController, Brightness>((ref) => StableBrightnessController());
