import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_controller.dart';
import 'glass_settings.dart';
import 'grain_controller.dart';
import 'providers.dart';
import 'theme_mode_controller.dart';

/// Vzhled profilu (sklo, zrno, motiv) uložený i na serveru -- stejný na
/// každém zařízení profilu a admin ho může profilu nastavit (táta: zatím
/// Expressive bez skla, dokud je v prohlížeči).
///
/// Při startu: server prázdný -> pošle se vzhled tohohle zařízení; jinak se
/// převezme ze serveru. Každá změna v Profil › Vzhled se pak odešle.
final appearanceSyncProvider = Provider<void>((ref) {
  final acting = ref.watch(authProvider.select((a) => a.valueOrNull?.acting?.id));
  if (acting == null) return;
  final sync = _AppearanceSync(ref);
  sync.start();
  ref.onDispose(sync.dispose);
});

class _AppearanceSync {
  _AppearanceSync(this._ref);

  final Ref _ref;
  final List<ProviderSubscription<Object?>> _subs = [];
  Timer? _push;
  bool _ready = false;

  static final _sliders = <String, StateNotifierProvider<GlassSliderController, double>>{
    'appearance.glass_frost': glassFrostProvider,
    'appearance.glass_tint': glassTintProvider,
    'appearance.glass_darkness': glassDarknessProvider,
    'appearance.glass_colorfulness': glassColorfulnessProvider,
  };

  Map<String, Object> _current() => {
        for (final e in _sliders.entries) e.key: _ref.read(e.value),
        'appearance.glass_tint_main': _ref.read(glassTintMainProvider),
        'appearance.glass_accent_tint': _ref.read(glassAccentTintProvider),
        'appearance.glass_tone': _ref.read(glassToneProvider).name,
        'appearance.glass_buttons': _ref.read(glassButtonsProvider),
        'appearance.glass_grain': _ref.read(glassGrainProvider),
        'appearance.liquid_glass_test': _ref.read(liquidGlassProvider),
        'appearance.no_grain': _ref.read(noGrainProvider),
        'appearance.half_grain': _ref.read(halfGrainProvider),
        'appearance.theme_mode': _ref.read(themeModeProvider).name,
      };

  Future<void> _apply(Map<String, dynamic> values) async {
    final prefs = await SharedPreferences.getInstance();
    for (final e in _sliders.entries) {
      final v = values[e.key];
      if (v is num) {
        _ref.read(e.value.notifier).preview(v.toDouble());
        await prefs.setDouble(e.key, v.toDouble());
      }
    }
    Future<void> flag(String key, Future<void> Function(bool) set) async {
      final v = values[key];
      if (v is bool) await set(v);
    }

    await flag('appearance.glass_tint_main', _ref.read(glassTintMainProvider.notifier).set);
    await flag('appearance.glass_accent_tint', _ref.read(glassAccentTintProvider.notifier).set);
    await flag('appearance.glass_buttons', _ref.read(glassButtonsProvider.notifier).set);
    await flag('appearance.glass_grain', _ref.read(glassGrainProvider.notifier).set);
    await flag('appearance.liquid_glass_test', _ref.read(liquidGlassProvider.notifier).set);
    await flag('appearance.no_grain', _ref.read(noGrainProvider.notifier).set);
    await flag('appearance.half_grain', _ref.read(halfGrainProvider.notifier).set);
    final tone = GlassToneMode.values.where((m) => m.name == values['appearance.glass_tone']).firstOrNull;
    if (tone != null) await _ref.read(glassToneProvider.notifier).set(tone);
    final theme = ThemeMode.values.where((m) => m.name == values['appearance.theme_mode']).firstOrNull;
    if (theme != null) await _ref.read(themeModeProvider.notifier).set(theme);
  }

  void start() {
    // Ovladače si svoje hodnoty načítají z úložiště asynchronně -- chvilku
    // počkat, ať se na server nepošlou výchozí hodnoty místo uložených.
    Future<void>.delayed(const Duration(seconds: 1), () async {
      try {
        final json = await _ref.read(apiClientProvider).getJson('/auth/me/appearance');
        final values = (json['values'] as Map<String, dynamic>?) ?? const {};
        if (values.isEmpty) {
          await _send();
        } else {
          await _apply(values);
        }
      } catch (_) {
        // Server nedostupný -- vzhled zůstane místní, zkusí se příště.
      }
      _ready = true;
    });
    void watch<T>(ProviderListenable<T> p) => _subs.add(_ref.listen<T>(p, (_, __) => _schedule()));
    for (final p in _sliders.values) {
      watch(p);
    }
    watch(glassTintMainProvider);
    watch(glassAccentTintProvider);
    watch(glassToneProvider);
    watch(glassButtonsProvider);
    watch(glassGrainProvider);
    watch(liquidGlassProvider);
    watch(noGrainProvider);
    watch(halfGrainProvider);
    watch(themeModeProvider);
  }

  void _schedule() {
    if (!_ready) return;
    _push?.cancel();
    // Jezdce mění stav při každém pohybu -- odeslat až po chvíli klidu.
    _push = Timer(const Duration(seconds: 2), () => unawaited(_send()));
  }

  Future<void> _send() async {
    try {
      await _ref.read(apiClientProvider).putJson('/auth/me/appearance', body: {'values': _current()});
    } catch (_) {}
  }

  void dispose() {
    _push?.cancel();
    for (final s in _subs) {
      s.close();
    }
  }
}
