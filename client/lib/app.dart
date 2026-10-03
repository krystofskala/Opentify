import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/reduced_motion.dart';
import 'routing/app_router.dart';
import 'state/appearance_sync.dart';
import 'state/audio_player_controller.dart';
import 'state/glass_settings.dart';
import 'state/grain_controller.dart';
import 'state/theme_mode_controller.dart';
import 'state/user_idle.dart';
import 'theme/accent_color.dart' show AnimatedAccent, accentTransitionCurve;
import 'theme/app_theme.dart';
import 'theme/selected_accent.dart';
import 'widgets/app_background.dart';
import 'widgets/auth_gate.dart';
import 'state/offline_controller.dart';
import 'widgets/now_playing_sheet.dart';
import 'widgets/top_fade_scroll_behavior.dart';
import 'widgets/toast.dart';
import 'state/connect_controller.dart';

const _defaultSeed = Colors.deepPurple;

/// Pro hlášky mimo konkrétní obrazovku (např. navázání z jiného zařízení).
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

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
    // Offline knihovna načtená hned (přehrávač se na ni ptá už u první skladby).
    ref.watch(offlineControllerProvider.select((s) => s.tracks.length));
    // Vzhled profilu ze serveru / na server (stejný na všech zařízeních).
    ref.watch(appearanceSyncProvider);
    // Opentify Connect: ostatní zařízení profilu (seznam, povely, převzetí).
    ref.watch(connectProvider);
    ref.listen<String?>(playerNoticeProvider, (_, message) {
      if (message == null) return;
      showToast(appMessengerKey.currentState, message);
      ref.read(playerNoticeProvider.notifier).state = null;
    });

    return MaterialApp.router(
      title: 'Opentify',
      scaffoldMessengerKey: appMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(seed: seed, brightness: Brightness.light),
      darkTheme: buildAppTheme(seed: seed, brightness: Brightness.dark),
      // Volba "Vzhled" v Profilu (výchozí tmavý), přepnutí animuje stejná
      // `themeAnimation*` jako změna barvy.
      // "Systém" přes ustálený jas (bez probliknutí světlého po návratu do appky).
      themeMode: switch (ref.watch(themeModeProvider)) {
        ThemeMode.system => ref.watch(stableBrightnessProvider) == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        final mode => mode,
      },
      routerConfig: router,
      scrollBehavior: const TopFadeScrollBehavior(),
      // Změna seedu (jiné album/interpret/skladba) přebarví celé téma
      // plynule -- ale krátce: 2,8 s přechodu znamenalo 2,8 s překreslování
      // skoro celé appky každý snímek při každé změně skladby (audit výkonu,
      // starší iPhone). Pomalý přechod zůstává jen u pozadí a přehrávače.
      themeAnimationDuration: const Duration(milliseconds: 500),
      themeAnimationCurve: accentTransitionCurve,
      // Zrnité pozadí pod úplně vším -- `Scaffold`y jsou průhledné
      // (`buildAppTheme`), takže prosvítá skrz. I přehrávač je teď průhledný
      // (pozadí appky pod hustě namrzlým sklem), takže se nikdy nezastavuje.
      // Klepnutí mimo textové pole zavře klávesnici (iOS to samo nedělá --
      // živě: po chybě hledání nešla klávesnice zavřít vůbec).
      builder: (context, child) => _DismissKeyboard(
          child: _maybeSimulatedInsets(
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
            noGrain: ref.watch(noGrainProvider),
            // Nad Navigatorem -- sdílený stav rozbalení přehrávače pro mini
            // přehrávač (začátek tažení) i `NowPlayingScreen` (viz now_playing_sheet.dart).
            // Tón skla v barvě skladby se přebarvuje spolu s pozadím
            // (`AnimatedAccent` = stejná délka a křivka).
            child: AnimatedAccent(
              // Tón skla: hlavní barva pozadí, nebo kontrastní akcent.
              color: (ref.watch(glassTintMainProvider)
                      ? backgroundMainColor(accent, Theme.of(context).brightness,
                          ref.watch(effectiveSupportTonesProvider), ref.watch(effectiveCoverCharacterProvider))
                      : null) ??
                  seed,
              builder: (context, tone) => GlassSettings(
                frost: ref.watch(glassFrostProvider),
                tint: ref.watch(glassTintProvider),
                tintColor: ref.watch(glassAccentTintProvider) ? tone : null,
                darkness: ref.watch(glassDarknessProvider),
                colorfulness: ref.watch(glassColorfulnessProvider),
                tone: ref.watch(glassToneProvider),
                grain: ref.watch(glassGrainProvider),
                fineGrain: ref.watch(fineGrainProvider),
                glassButtons: ref.watch(glassButtonsProvider),
                liquid: ref.watch(liquidGlassProvider) && !ref.watch(glassOffProvider),
                solid: ref.watch(glassOffProvider),
                // Popisky při najetí myší rušily (živě nahlášeno) -- vypnuté
                // všude; čtečka obrazovky je dostane dál.
                child: TooltipVisibility(
                  visible: false,
                  child: NowPlayingSheetHost(child: AuthGate(child: child ?? const SizedBox.shrink())),
                ),
              ),
            ),
          )))),
    );
  }
}

/// `--dart-define=SIMULATE_INSETS=true` (jen kontrolní buildy): iPhone-like
/// safe-area insety (47 nahoře / 34 dole), aby šlo na desktopu ověřit, že
/// tab bar, mini přehrávač, hlavičky a přehrávač insety respektují.
const _simulateInsets = bool.fromEnvironment('SIMULATE_INSETS');

Widget _maybeSimulatedInsets(BuildContext context, Widget child) {
  final mq = MediaQuery.of(context);
  // Omezení pohybu: na webu Flutter `prefers-reduced-motion` do
  // `disableAnimations` nepropisuje -- doplníme ho, ať celá appka čte jen
  // `MediaQuery.disableAnimationsOf`.
  final reduce = !mq.disableAnimations && systemPrefersReducedMotion();
  if (!_simulateInsets && !reduce) return child;
  const insets = EdgeInsets.only(top: 47, bottom: 34);
  return MediaQuery(
    data: mq.copyWith(
      padding: _simulateInsets ? insets : null,
      viewPadding: _simulateInsets ? insets : null,
      disableAnimations: mq.disableAnimations || reduce,
    ),
    child: child,
  );
}

/// Klepnutí kamkoli mimo textové pole zavře klávesnici. Tlačítka a pole
/// samotná vyhrají gesto dřív (jsou hlouběji), sem dojde jen klepnutí do
/// prázdna.
class _DismissKeyboard extends StatelessWidget {
  const _DismissKeyboard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Otevřená klávesnice (dotyková zařízení): tlačítko „Skrýt" těsně nad ní
    // -- klepnutí mimo pole nestačilo (živě: "pořád problém zavřít").
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final touch = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: child,
        ),
        if (touch && keyboard > 80)
          Positioned(
            right: 12,
            bottom: keyboard + 8,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
              shape: const StadiumBorder(),
              elevation: 3,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Symbols.keyboard_hide_rounded, size: 20, color: Theme.of(context).colorScheme.onSurface),
                      const SizedBox(width: 6),
                      Text('Skrýt', style: Theme.of(context).textTheme.labelLarge),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
