import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/artist/artist_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/local_library_screen.dart';
import '../features/player/now_playing_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/release/release_screen.dart';
import '../features/search/search_screen.dart';
import 'home_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/library', builder: (context, state) => const LocalLibraryScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
          ]),
        ],
      ),
      GoRoute(
        path: '/artists/:artistId',
        builder: (context, state) => ArtistScreen(artistId: state.pathParameters['artistId']!),
      ),
      GoRoute(
        path: '/releases/:releaseId',
        builder: (context, state) => ReleaseScreen(releaseId: state.pathParameters['releaseId']!),
      ),
      GoRoute(
        path: '/now-playing',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: const NowPlayingScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeOutCubic))
                .animate(animation),
            child: child,
          ),
        ),
      ),
    ],
  );
});
