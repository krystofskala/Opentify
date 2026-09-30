import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_tokens.dart';
import '../widgets/glass/glass.dart';
import '../widgets/glass/liquid_glass.dart';
import '../widgets/now_playing_sheet.dart' show HiddenUnderPlayer;
import '../widgets/player_bar.dart';

/// Bottom-nav shell pro čtyři hlavní destinace (Domů/Hledat/Knihovna/Profil) --
/// Artist/Release se pushují nad ním jako celoobrazovkové detaily, ne jako další tab.
///
/// Plovoucí skleněný tab bar + mini přehrávač nad ním (HIG Tab bars: "a tab
/// bar floats above content"), `extendBody` -- obsah pod nimi pokračuje a
/// prosvítá rozmazaný. Scaffold posílá jejich výšku jako
/// `MediaQuery.padding.bottom`, kterou si seznamy přičítají (`navBottomInset`).
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _tabs = [
    GlassTabItem(icon: Symbols.home_rounded, label: 'Domů'),
    GlassTabItem(icon: Symbols.search_rounded, label: 'Hledat'),
    GlassTabItem(icon: Symbols.library_music_rounded, label: 'Knihovna'),
    GlassTabItem(icon: Symbols.person_rounded, label: 'Profil'),
  ];

  @override
  Widget build(BuildContext context) {
    // `LiquidScope` + `LiquidSource.page`: obsah stránky pod lištami jde
    // zachytit pro sklo s lomem (Profil › Vzhled › "Lom skla (test)").
    return HiddenUnderPlayer(
        child: LiquidScope(
            child: Scaffold(
      extendBody: true,
      body: LiquidSource.page(child: navigationShell),
      // Na širokém okně plovoucí skupina (přehrávač + tab bar) uprostřed s
      // omezenou šířkou -- ne pruh přes celých 2000 px.
      bottomNavigationBar: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kFloatingBarMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Vlastní měkký stín i u mini přehrávače -- průhledné sklo se
              // jinak na tmavé stránce slévalo s okolím (živě nahlášeno).
              MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                // Mini přehrávač při prvním puštění vyjede, po zavření
                // zajede -- dřív se tab bar skokem posunul.
                child: AnimatedSize(
                  duration: Motion.sheetIn.duration,
                  curve: Motion.sheetIn,
                  alignment: Alignment.bottomCenter,
                  child: const PlayerBar(),
                ),
              ),
              GlassTabBar(
                items: _tabs,
                selectedIndex: navigationShell.currentIndex,
                // Znovu klepnutý aktivní tab = zpět na jeho první stránku (iOS).
                onSelected: (index) =>
                    navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex),
              ),
            ],
          ),
        ),
      ),
    )));
  }
}

/// Spodní odsazení seznamů na hlavních tabech -- obsah pod plovoucím tab
/// barem (`HomeShell.extendBody`) se jinak na konci schová pod něj. Mimo
/// shell (detaily s vlastní lištou přehrávače) je to 0.
double navBottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom;
