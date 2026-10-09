import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart' show appMessengerKey;
import '../widgets/toast.dart';

/// Tipy k funkcím (návrh 9. 10., schváleno): jen jako reakce, když uživatel
/// něco dělá opakovaně zdlouhavě nebo narazí na situaci, kterou funkce řeší.
/// Nejvýš 1 tip za den, ne v první minutě po otevření, každý nejvýš 2× (podruhé
/// po 14 dnech), po prvním použití funkce už nikdy. Počítadla jen v zařízení.
/// Vypínají se v Profilu › Vzhled; všechno je i v „Co Opentify umí“.
enum Hint {
  queueSwipe,
  laterSwipe,
  endless,
  dislike,
  albumDownload,
  albumQueue,
  desktopKeys,
  floatingPlayer,
  abRepeat,
  spokenControls,
  sleepTimer,
}

/// Text tipu (stejný katalog používá i stránka „Co Opentify umí“).
const hintTexts = <Hint, String>{
  Hint.queueSwipe: 'Rychleji: tah po skladbě doprava = hrát jako další, doleva = na konec fronty.',
  Hint.laterSwipe: 'Delší tah po skladbě doleva ji uloží do „Poslechnout později“.',
  Hint.endless: 'Aby hudba nedohrála: klepni na opakování, dokud se neukáže ∞ – Opentify pak hraje dál podobnou hudbu.',
  Hint.dislike: 'Nebaví tě to? Podrž srdce a skladba zmizí z mixů i rádií.',
  Hint.albumDownload: 'Zkus v menu alba „Stáhnout celé album“ – u alb bývá větší šance, že se najdou.',
  Hint.albumQueue: 'Podrž obal alba a zařadíš ho rovnou do fronty.',
  Hint.desktopKeys: 'Na počítači: PgDn / PgUp o stránku, klik kolečkem = rychlý posun, mezerník = pauza.',
  Hint.floatingPlayer: 'Přehrávač může plavat nad ostatními okny: ⋯ v přehrávači › Plovoucí přehrávač.',
  Hint.abRepeat: 'Chceš kus pořád dokola? ⋯ v přehrávači › A-B opakování.',
  Hint.spokenControls: 'U knih jsou tlačítka ±30 s a rychlost – rychlost si každá kniha pamatuje.',
  Hint.sleepTimer: 'Usínáš u toho? ⋯ v přehrávači › Uspávač, i do konce kapitoly.',
};

/// Kolikrát se musí zdlouhavý postup opakovat (v okně `_windowFor`).
const _thresholds = <Hint, int>{
  Hint.queueSwipe: 3,
  Hint.laterSwipe: 3,
  Hint.endless: 2,
  Hint.dislike: 3,
  Hint.albumDownload: 1,
  Hint.albumQueue: 3,
  Hint.desktopKeys: 1,
  Hint.floatingPlayer: 3,
  Hint.abRepeat: 3,
  Hint.spokenControls: 3,
  Hint.sleepTimer: 1,
};

Duration _windowFor(Hint h) => switch (h) {
      Hint.abRepeat => const Duration(minutes: 1),
      Hint.spokenControls => const Duration(minutes: 5),
      Hint.floatingPlayer => const Duration(days: 1),
      _ => const Duration(days: 7),
    };

const _prefsKey = 'hints.v1';
const _maxShows = 2;
const _again = Duration(days: 14);

class HintsState {
  const HintsState({this.enabled = true, this.used = const {}, this.shows = const {}, this.lastShown = const {}, this.events = const {}, this.lastAny});

  final bool enabled;
  final Set<Hint> used;
  final Map<Hint, int> shows;
  final Map<Hint, DateTime> lastShown;
  final Map<Hint, List<DateTime>> events;
  final DateTime? lastAny;

  HintsState copyWith({
    bool? enabled,
    Set<Hint>? used,
    Map<Hint, int>? shows,
    Map<Hint, DateTime>? lastShown,
    Map<Hint, List<DateTime>>? events,
    DateTime? lastAny,
  }) =>
      HintsState(
        enabled: enabled ?? this.enabled,
        used: used ?? this.used,
        shows: shows ?? this.shows,
        lastShown: lastShown ?? this.lastShown,
        events: events ?? this.events,
        lastAny: lastAny ?? this.lastAny,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'used': [for (final h in used) h.name],
        'shows': {for (final e in shows.entries) e.key.name: e.value},
        'lastShown': {for (final e in lastShown.entries) e.key.name: e.value.toIso8601String()},
        'events': {for (final e in events.entries) e.key.name: [for (final t in e.value) t.toIso8601String()]},
        if (lastAny != null) 'lastAny': lastAny!.toIso8601String(),
      };

  static HintsState fromJson(Map<String, dynamic> j) {
    Hint? byName(String n) => Hint.values.where((h) => h.name == n).firstOrNull;
    return HintsState(
      enabled: j['enabled'] as bool? ?? true,
      used: {for (final n in (j['used'] as List? ?? const [])) byName(n as String)}.whereType<Hint>().toSet(),
      shows: {
        for (final e in (j['shows'] as Map? ?? const {}).entries)
          if (byName(e.key as String) != null) byName(e.key as String)!: (e.value as num).toInt(),
      },
      lastShown: {
        for (final e in (j['lastShown'] as Map? ?? const {}).entries)
          if (byName(e.key as String) != null) byName(e.key as String)!: DateTime.parse(e.value as String),
      },
      events: {
        for (final e in (j['events'] as Map? ?? const {}).entries)
          if (byName(e.key as String) != null)
            byName(e.key as String)!: [for (final t in (e.value as List)) DateTime.parse(t as String)],
      },
      lastAny: j['lastAny'] == null ? null : DateTime.parse(j['lastAny'] as String),
    );
  }
}

class HintsController extends StateNotifier<HintsState> {
  HintsController({DateTime Function()? clock, void Function(Hint hint, String text, VoidCallback never)? show})
      : _clock = clock ?? DateTime.now,
        _show = show ?? _toast,
        _startedAt = (clock ?? DateTime.now)(),
        super(const HintsState()) {
    unawaited(_load());
  }

  final DateTime Function() _clock;
  final void Function(Hint hint, String text, VoidCallback never) _show;
  final DateTime _startedAt;

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw != null && mounted) state = HintsState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  void _save() {
    final json = jsonEncode(state.toJson());
    unawaited(SharedPreferences.getInstance().then((p) => p.setString(_prefsKey, json)).catchError((Object _) => false));
  }

  Future<void> setEnabled(bool on) async {
    state = state.copyWith(enabled: on);
    _save();
  }

  /// Uživatel funkci použil -- tip k ní už nikdy.
  void used(Hint h) {
    if (state.used.contains(h)) return;
    state = state.copyWith(used: {...state.used, h}, events: {...state.events}..remove(h));
    _save();
  }

  /// Zdlouhavý postup / situace, kterou funkce řeší. Po dosažení prahu
  /// (a v mezích zásad) ukáže tip.
  void signal(Hint h) {
    if (state.used.contains(h)) return;
    final now = _clock();
    final recent = [...?state.events[h], now].where((t) => now.difference(t) <= _windowFor(h)).toList();
    state = state.copyWith(events: {...state.events, h: recent});
    if (recent.length >= (_thresholds[h] ?? 3) && _mayShow(h, now)) {
      state = state.copyWith(
        shows: {...state.shows, h: (state.shows[h] ?? 0) + 1},
        lastShown: {...state.lastShown, h: now},
        lastAny: now,
        events: {...state.events}..remove(h),
      );
      _show(h, hintTexts[h]!, () => never(h));
    }
    _save();
  }

  /// „Už ne“ u tipu -- jako by funkci znal.
  void never(Hint h) => used(h);

  bool _mayShow(Hint h, DateTime now) {
    if (!state.enabled) return false;
    if (now.difference(_startedAt) < const Duration(minutes: 1)) return false;
    final last = state.lastAny;
    if (last != null && last.year == now.year && last.month == now.month && last.day == now.day) return false;
    final shows = state.shows[h] ?? 0;
    if (shows >= _maxShows) return false;
    final lastThis = state.lastShown[h];
    if (lastThis != null && now.difference(lastThis) < _again) return false;
    return true;
  }

  static void _toast(Hint hint, String text, VoidCallback never) {
    showToast(
      appMessengerKey.currentState,
      'Tip: $text',
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: 'Už ne', onPressed: never),
    );
  }
}

final hintsProvider = StateNotifierProvider<HintsController, HintsState>((ref) => HintsController());
