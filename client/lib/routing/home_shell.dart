import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../widgets/player_bar.dart';

/// Vyplněná varianta ikony pro vybraný tab -- `Symbols.*` nese "fill" jako
/// osu variabilního fontu (`VariedIcon.varied`), ne jako samostatný název
/// ikony jako staré Material Icons (`Icons.home` vs `Icons.home_outlined`).
Widget _filled(IconData icon) => VariedIcon.varied(icon, fill: 1);

/// Bottom-nav shell pro čtyři hlavní destinace (Domů/Hledat/Knihovna/Profil) --
/// Artist/Release se pushují nad ním jako celoobrazovkové detaily, ne jako další tab.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PlayerBar(),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: navigationShell.goBranch,
            destinations: [
              NavigationDestination(
                icon: const Icon(Symbols.home_rounded),
                selectedIcon: _filled(Symbols.home_rounded),
                label: 'Domů',
              ),
              NavigationDestination(
                icon: const Icon(Symbols.search_rounded),
                selectedIcon: _filled(Symbols.search_rounded),
                label: 'Hledat',
              ),
              NavigationDestination(
                icon: const Icon(Symbols.library_music_rounded),
                selectedIcon: _filled(Symbols.library_music_rounded),
                label: 'Knihovna',
              ),
              NavigationDestination(
                icon: const Icon(Symbols.person_rounded),
                selectedIcon: _filled(Symbols.person_rounded),
                label: 'Profil',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
