import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/app_router.dart';
import 'state/audio_player_controller.dart';
import 'state/glass_settings.dart';
import 'state/grain_controller.dart';
import 'state/theme_mode_controller.dart';
import 'state/user_idle.dart';
import 'theme/accent_color.dart' show AnimatedAccent, accentTransitionCurve, accentTransitionDuration;
import 'theme/app_theme.dart';
import 'theme/selected_accent.dart';
import 'widgets/app_background.dart';
import 'widgets/now_playing_sheet.dart';
import 'widgets/top_fade_scroll_behavior.dart';

const _defaultSeed = Colors.deepPurple;

class OpentifyApp extends ConsumerWidget {
  const OpentifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // Seed M3 tématu i barva pozadí z JEDNOHO zdroje (`effectiveAccentProvider`):
    // hrající skladba > otevřené album/interpret > naposledy platná barva.
    // Výchozí fialová jen úplně na začátku.
    final accent = ref.watch(effectiveAccentProvider);
    final seed = accent ?? _defaultSeed;
    final isPlaying = ref.watch(audioPlayerControllerProvider.select((s) => s.isPlaying));

    return MaterialApp.router(
      title: 'Opentify',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(seed: seed, brightness: Brightness.light),
      darkTheme: buildAppTheme(seed: seed, brightness: Brightness.dark),
      // Volba "Vzhled" v Profilu (výchozí tmavý), přepnutí animuje stejná
      // `themeAnimation*` jako změna barvy.
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
      scrollBehavior: const TopFadeScrollBehavior(),
      // Změna seedu (jiné album/interpret/skladba) přebarví celé téma
      // plynule, stejnou křivkou jako přehrávač a pozadí -- ne skokem.
      themeAnimationDuration: accentTransitionDuration,
      themeAnimationCurve: accentTransitionCurve,
      // Zrnité pozadí pod úplně vším -- `Scaffold`y jsou průhledné
      // (`buildAppTheme`), takže prosvítá skrz. I přehrávač je teď průhledný
      // (pozadí appky pod hustě namrzlým sklem), takže se nikdy nezastavuje.
      builder: (context, child) => _maybeSimulatedInsets(
          context,
          UserActivityListener(
              child: AppBackground(
            selectedAccent: accent,
            supportTones: ref.watch(effectiveSupportTonesProvider),
            character: ref.watch(effectiveCoverCharacterProvider),
            brightness: Theme.of(context).brightness,
            isPlaying: isPlaying,
            hidden: false,
            fineGrain: ref.watch(fineGrainProvider),
            // Nad Navigatorem -- sdílený stav rozbalení přehrávače pro mini
            // přehrávač (začátek tažení) i `NowPlayingScreen` (viz now_playing_sheet.dart).
            // Tón skla v barvě skladby se přebarvuje spolu s pozadím
            // (`AnimatedAccent` = stejná délka a křivka).
            child: AnimatedAccent(
              color: seed,
              builder: (context, tone) => GlassSettings(
                frost: ref.watch(glassFrostProvider),
                tint: ref.watch(glassTintProvider),
                tintColor: ref.watch(glassAccentTintProvider) ? tone : null,
                glassButtons: ref.watch(glassButtonsProvider),
                liquid: ref.watch(liquidGlassProvider),
                // Popisky při najetí myší rušily (živě nahlášeno) -- vypnuté
                // všude; čtečka obrazovky je dostane dál.
                child: TooltipVisibility(
                  visible: false,
                  child: NowPlayingSheetHost(child: child ?? const SizedBox.shrink()),
                ),
              ),
            ),
          ))),
    );
  }
}

/// `--dart-define=SIMULATE_INSETS=true` (jen kontrolní buildy): iPhone-like
/// safe-area insety (47 nahoře / 34 dole), aby šlo na desktopu ověřit, že
/// tab bar, mini přehrávač, hlavičky a přehrávač insety respektují.
const _simulateInsets = bool.fromEnvironment('SIMULATE_INSETS');

Widget _maybeSimulatedInsets(BuildContext context, Widget child) {
  if (!_simulateInsets) return child;
  const insets = EdgeInsets.only(top: 47, bottom: 34);
  final mq = MediaQuery.of(context);
  return MediaQuery(data: mq.copyWith(padding: insets, viewPadding: insets), child: child);
}
