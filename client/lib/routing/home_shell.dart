import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../widgets/glass/glass.dart';
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
    return Scaffold(
      extendBody: true,
      body: navigationShell,
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
              // Jeden stín na skupinu (má ho tab bar) -- žádné vrstvené stíny.
              MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: const PlayerBar(shadow: false),
              ),
              GlassTabBar(
                items: _tabs,
                selectedIndex: navigationShell.currentIndex,
                onSelected: navigationShell.goBranch,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spodní odsazení seznamů na hlavních tabech -- obsah pod plovoucím tab
/// barem (`HomeShell.extendBody`) se jinak na konci schová pod něj. Mimo
/// shell (detaily s vlastní lištou přehrávače) je to 0.
double navBottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom;
