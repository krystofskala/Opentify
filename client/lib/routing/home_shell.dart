import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom-nav shell pro dvě hlavní destinace (Domů/Hledat) -- Artist/Release
/// se pushují nad ním jako celoobrazovkové detaily, ne jako další tab.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: navigationShell.goBranch,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Domů'),
          NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: 'Hledat'),
        ],
      ),
    );
  }
}
