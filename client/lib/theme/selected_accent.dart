import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/audio_player_controller.dart';
import 'accent_color.dart';

/// Je přehrávač otevřený (skladba načtená -- hraje i na pauze)? Pak barvu
/// appky určuje skladba (viz [EffectiveAccent], pravidlo 1).
final trackIsPlayingProvider = Provider<bool>((ref) {
  return ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying != null));
});

/// Obrázky otevřených detailů (souběžně se `screenAccentStackProvider`, ze
/// kterého barvu čte) -- pro doplňkové tóny obalu (`supportTonesProvider`).
class ScreenImageStack extends StateNotifier<List<MapEntry<Object, String>>> {
  ScreenImageStack() : super(const []);

  void set(Object owner, String url) {
    final index = state.indexWhere((e) => identical(e.key, owner));
    if (index >= 0) {
      if (state[index].value == url) return;
      state = [...state]..[index] = MapEntry(owner, url);
    } else {
      state = [...state, MapEntry(owner, url)];
    }
  }

  void remove(Object owner) {
    state = state.where((e) => !identical(e.key, owner)).toList();
  }
}

final screenImageStackProvider =
    StateNotifierProvider<ScreenImageStack, List<MapEntry<Object, String>>>((ref) => ScreenImageStack());

/// Vítězný zdroj barvy: barva + obrázek, ze kterého je (kvůli doplňkovým
/// tónům). `imageUrl` může být `null` i u známé barvy.
typedef AccentSource = ({Color? accent, String? imageUrl});

/// JEDINÝ zdroj barvy appky (seed M3 tématu, zrnité pozadí, tónování
/// hlaviček, přehrávač). Pravidla (podle uživatele, sjednocená po několika
/// úpravách):
///
///   1. přehrávač je otevřený (skladba načtená -- hraje i na pauze):
///      vždy barva skladby, i nad otevřeným albem/interpretem/playlistem;
///   2. přehrávač je zavřený: barva otevřené obrazovky (album, interpret,
///      playlist);
///   3. jinak výchozí barvy (`null` -> pestré výchozí pozadí).
///
/// Dokud barva nové skladby není spočítaná (`accentColor == null`), drží se
/// předchozí barva -- žádné probliknutí přes výchozí/albovou.
class EffectiveAccent extends StateNotifier<AccentSource> {
  EffectiveAccent(this._ref) : super((accent: null, imageUrl: null)) {
    _recompute();
    // Vstupy se mění mimo build (mikroúloha v `ScreenAccent`, asynchronní
    // extrakce barvy v přehrávači), takže zápis stavu tady je bezpečný.
    _ref.listen<Color?>(activeScreenAccentProvider, (_, __) => _recompute());
    _ref.listen(screenImageStackProvider, (_, __) => _recompute());
    _ref.listen<bool>(audioPlayerControllerProvider.select((s) => s.nowPlaying != null), (_, __) => _recompute());
    _ref.listen<Color?>(audioPlayerControllerProvider.select((s) => s.accentColor), (_, __) => _recompute());
  }

  final Ref _ref;

  void _recompute() {
    final playback = _ref.read(audioPlayerControllerProvider);
    AccentSource next;
    if (playback.nowPlaying != null) {
      // 1. Otevřený přehrávač -- barva skladby (dokud se nespočítá, drží se
      // dosavadní).
      next = playback.accentColor != null
          ? (accent: playback.accentColor, imageUrl: playback.nowPlaying!.artworkUrl)
          : state;
    } else {
      // 2./3. Bez přehrávače -- otevřená obrazovka, jinak výchozí barvy.
      final screen = _ref.read(activeScreenAccentProvider);
      final images = _ref.read(screenImageStackProvider);
      next = screen != null
          ? (accent: screen, imageUrl: images.isEmpty ? null : images.last.value)
          : (accent: null, imageUrl: null);
    }
    if (next != state) state = next;
  }
}

final effectiveAccentSourceProvider =
    StateNotifierProvider<EffectiveAccent, AccentSource>((ref) => EffectiveAccent(ref));

/// Barva appky -- viz [EffectiveAccent].
final effectiveAccentProvider = Provider<Color?>((ref) => ref.watch(effectiveAccentSourceProvider).accent);

/// Až 2 doplňkové tóny z obalu vítězného zdroje (±40° od hlavní barvy) pro
/// vedlejší sloty gradientu pozadí; prázdné, dokud se nespočítají, u šedých
/// obalů nebo bez obrázku -- pozadí pak použije syntetický posun odstínu.
final effectiveSupportTonesProvider = Provider<List<Color>>((ref) {
  final url = ref.watch(effectiveAccentSourceProvider.select((s) => s.imageUrl));
  if (url == null) return const [];
  return ref.watch(supportTonesProvider(url)).valueOrNull ?? const [];
});

/// Charakter obalu vítězného zdroje (sytost/světlost celé plochy) -- viz
/// [CoverCharacter]; `null` bez obrázku nebo než se spočítá (pozadí pak
/// vychází jen z hlavní barvy).
final effectiveCoverCharacterProvider = Provider<CoverCharacter?>((ref) {
  final url = ref.watch(effectiveAccentSourceProvider.select((s) => s.imageUrl));
  if (url == null) return null;
  return ref.watch(coverCharacterProvider(url)).valueOrNull;
});
