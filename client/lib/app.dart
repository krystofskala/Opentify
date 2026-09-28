import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/app_router.dart';
import 'state/audio_player_controller.dart';
import 'theme/accent_color.dart';
import 'theme/app_theme.dart';
import 'widgets/app_background.dart';

const _defaultSeed = Colors.deepPurple;

class OpentifyApp extends ConsumerWidget {
  const OpentifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // "PixelPlay"-styl dynamické zabarvení: seed M3 palety appky se ladí
    // podle toho, na co se uživatel PRÁVĚ DÍVÁ (barva alba na Release, barva
    // interpreta na Artist -- `activeScreenAccentProvider`), a jen když
    // žádná taková obrazovka není otevřená (Home, Search, ...) padá zpátky
    // na barvu právě hrající skladby -- dřív to bylo jen naopak (vázané
    // výhradně na přehrávač), takže procházení cizích alb/interpretů zůstalo
    // barevně "mrtvé" (výchozí fialová), dokud něco nezačalo hrát.
    final screenAccent = ref.watch(activeScreenAccentProvider);
    final playingAccent = ref.watch(audioPlayerControllerProvider.select((s) => s.accentColor));
    final seed = screenAccent ?? playingAccent ?? _defaultSeed;
    // Vícebarevný gradient jen tam, kde žádná obrazovka barvu explicitně
    // neurčuje (Domů/Hledání/Knihovna/Profil) -- jakmile se otevře Album/
    // Interpret a nastaví `screenAccent`, `AppBackground` zredukuje paletu na
    // jeden odstín, přesně jak žádal uživatel ("barvy zmizí").
    final isMulti = screenAccent == null;
    final isPlaying = ref.watch(audioPlayerControllerProvider.select((s) => s.isPlaying));

    return MaterialApp.router(
      title: 'Opentify',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(seed: seed, brightness: Brightness.light),
      darkTheme: buildAppTheme(seed: seed, brightness: Brightness.dark),
      routerConfig: router,
      // Změna seedu (jiné album/interpret/skladba) přebarví celé téma
      // plynule, stejnou křivkou jako přehrávač a pozadí -- ne skokem.
      themeAnimationDuration: accentTransitionDuration,
      themeAnimationCurve: accentTransitionCurve,
      // Gradient + zrno pozadí pod úplně vším -- `Theme.of(context)` tady už
      // je vyřešené `theme`/`darkTheme` podle aktuální platformní jasnosti,
      // takže `AppBackground` dostane správný `brightness` bez druhého zdroje
      // pravdy. `Scaffold`y jsou teď průhledné (`buildAppTheme`), takže tohle
      // prosvítá skrz -- kromě `NowPlayingScreen`/`PlayerBar`, které mají
      // vlastní neprůhledné pozadí a tohle jednoduše překryjí.
      builder: (context, child) => AppBackground(
        seed: seed,
        brightness: Theme.of(context).brightness,
        isMulti: isMulti,
        isPlaying: isPlaying,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
