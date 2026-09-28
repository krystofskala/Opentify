import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'routing/app_router.dart';
import 'state/audio_player_controller.dart';
import 'theme/accent_color.dart';
import 'theme/app_theme.dart';
import 'theme/selected_accent.dart';
import 'widgets/app_background.dart';

const _defaultSeed = Colors.deepPurple;

class OpentifyApp extends ConsumerWidget {
  const OpentifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // Seed M3 tématu: barva právě prohlížené obrazovky (album/interpret),
    // jinak naposledy vybraná barva relace (poslední otevřené album nebo
    // hrající skladba) -- stejná, jakou má pozadí, takže se téma a pozadí
    // po návratu na Domů nerozejdou. Výchozí fialová jen úplně na začátku.
    final screenAccent = ref.watch(activeScreenAccentProvider);
    final selectedAccent = ref.watch(selectedAccentProvider);
    final seed = screenAccent ?? selectedAccent ?? _defaultSeed;
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
      // Zrnité pozadí pod úplně vším -- `Scaffold`y jsou průhledné
      // (`buildAppTheme`), takže prosvítá skrz. Přehrávač má vlastní plnou
      // výplň; když je otevřený, pozadí se zastaví (není vidět).
      builder: (context, child) => ListenableBuilder(
        listenable: router.routerDelegate,
        builder: (context, _) => AppBackground(
          selectedAccent: screenAccent ?? selectedAccent,
          brightness: Theme.of(context).brightness,
          isPlaying: isPlaying,
          hidden: _isNowPlayingOpen(router),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}

bool _isNowPlayingOpen(GoRouter router) {
  bool contains(List<RouteMatchBase> matches) {
    for (final match in matches) {
      if (match is ImperativeRouteMatch && contains(match.matches.matches)) return true;
      if (match is ShellRouteMatch && contains(match.matches)) return true;
      final route = match.route;
      if (route is GoRoute && route.path == '/now-playing') return true;
    }
    return false;
  }

  try {
    return contains(router.routerDelegate.currentConfiguration.matches);
  } catch (_) {
    return false;
  }
}
