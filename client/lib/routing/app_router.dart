import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/diagnostics.dart';

import '../features/library/shared_playlists_screen.dart';
import '../features/library/shazam_collection_screen.dart';
import '../features/artist/artist_discography_screen.dart';
import '../features/artist/artist_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/local_library_screen.dart';
import '../features/library/liked_songs_screen.dart';
import '../features/library/listen_later_screen.dart';
import '../features/library/playlist_detail_screen.dart';
import '../features/player/now_playing_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/profile/year_in_review_screen.dart';
import '../features/browse/browse_category_screen.dart';
import '../features/release/release_screen.dart';
import '../features/search/search_screen.dart';
import '../features/shazam/shazam_screen.dart';
import '../features/tuner/tuner_screen.dart';
import '../features/wrapped/wrapped_hub_screen.dart';
import '../features/wrapped/wrapped_story_screen.dart';
import 'home_shell.dart';
import '../features/share/track_link_screen.dart';
import '../features/blend/blend_screen.dart';
import '../core/native_nav.dart';
import '../features/profile/verify_downloads_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
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
        path: '/artists/:artistId/discography',
        builder: (context, state) => ArtistDiscographyScreen(
          artistId: state.pathParameters['artistId']!,
          initialType: state.uri.queryParameters['type'] ?? 'all',
        ),
      ),
      GoRoute(path: '/blends', builder: (context, state) => const BlendScreen()),
      // „Poslat v Opentify" -- poslaná skladba (features/share).
      GoRoute(
        path: '/track/:recordingId',
        builder: (context, state) => TrackLinkScreen(recordingId: state.pathParameters['recordingId']!),
      ),
      GoRoute(
        path: '/releases/:releaseId',
        builder: (context, state) => ReleaseScreen(
          releaseId: state.pathParameters['releaseId']!,
          highlightTrackId: state.uri.queryParameters['track'],
        ),
      ),
      GoRoute(
        path: '/browse/:categoryId',
        builder: (context, state) => BrowseCategoryScreen(categoryId: state.pathParameters['categoryId']!),
      ),
      GoRoute(
        path: '/library/later',
        builder: (context, state) => const ListenLaterScreen(),
      ),
      GoRoute(
        path: '/library/shared',
        builder: (context, state) => const SharedPlaylistsScreen(),
      ),
      GoRoute(
        path: '/library/shazam',
        builder: (context, state) => const ShazamCollectionScreen(),
      ),
      GoRoute(
        path: '/library/liked',
        builder: (context, state) => const LikedSongsScreen(),
      ),
      GoRoute(
        path: '/playlists/:playlistId',
        builder: (context, state) => PlaylistDetailScreen(playlistId: state.pathParameters['playlistId']!),
      ),
      GoRoute(
        path: '/wrapped',
        builder: (context, state) => const WrappedHubScreen(),
      ),
      GoRoute(
        path: '/wrapped/:period',
        builder: (context, state) => WrappedStoryScreen(period: state.pathParameters['period']!),
      ),
      GoRoute(
        path: '/shazam',
        builder: (context, state) => ShazamScreen(autoStart: state.uri.queryParameters['start'] == '1'),
      ),
      GoRoute(
        path: '/verify-downloads',
        builder: (context, state) => const VerifyDownloadsScreen(),
      ),
      GoRoute(
        path: '/tuner',
        builder: (context, state) => const TunerScreen(),
      ),
      GoRoute(
        path: '/year-in-review',
        builder: (context, state) => const YearInReviewScreen(),
      ),
      GoRoute(
        path: '/now-playing',
        // Bez vlastní animace a průhledná -- polohu přehrávače řídí
        // `NowPlayingSheetController` (interaktivní tažení z mini
        // přehrávače), stránka pod ním zůstává vidět během vysouvání.
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          opaque: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          child: const NowPlayingScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) => child,
        ),
      ),
    ],
  );
  // Kroky navigace do "černé skříňky" (diagnostika zamrzání).
  router.routerDelegate.addListener(() {
    diagNote('route ${router.routerDelegate.currentConfiguration.uri}');
  });
  // iOS: Ovládací centrum / upozornění Shazamu otevírají obrazovky přes nativní most.
  NativeNav.attach(router);
  return router;
});
