import 'package:flutter/foundation.dart' show ValueNotifier;
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
import '../features/browse/tag_screen.dart';
import '../features/release/release_screen.dart';
import '../features/search/search_screen.dart';
import '../features/shazam/shazam_screen.dart';
import '../features/tuner/tuner_screen.dart';
import '../features/profile/discoveries_screen.dart';
import '../features/profile/history_screen.dart';
import '../features/spoken/podcast_screens.dart';
import '../features/spoken/spoken_screens.dart';
import '../state/app_mode.dart';
import '../features/wrapped/wrapped_hub_screen.dart';
import '../features/wrapped/wrapped_story_screen.dart';
import '../features/games/games_screen.dart';
import 'branches.dart';
import 'home_shell.dart';
import '../features/share/track_link_screen.dart';
import '../features/blend/blend_screen.dart';
import '../core/native_nav.dart';
import '../features/profile/playback_test_screen.dart';
import '../features/profile/verify_downloads_screen.dart';
import '../features/library/playlist_join_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = _AppRouter(
    initialLocation: '/',
    routingConfig: ValueNotifier(RoutingConfig(
      // `/artists/x` z kterékoli záložky -> detail v té záložce.
      redirect: (context, state) => branchRedirect(state.uri),
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) => HomeShell(navigationShell: navigationShell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(path: '/', builder: (context, state) => const ModeSwitch(music: HomeScreen(), spoken: SpokenHomeScreen()), routes: _detailRoutes()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/search', builder: (context, state) => const ModeSwitch(music: SearchScreen(), spoken: SpokenSearchScreen()), routes: _detailRoutes()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/library', builder: (context, state) => const ModeSwitch(music: LocalLibraryScreen(), spoken: SpokenLibraryScreen()), routes: _detailRoutes()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen(), routes: _detailRoutes()),
            ]),
          ],
        ),
        GoRoute(
          path: '/playlist-join/:code',
          builder: (context, state) => PlaylistJoinScreen(code: state.pathParameters['code']!),
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
          path: '/tuner',
          builder: (context, state) => const TunerScreen(),
        ),
        GoRoute(
          path: '/discoveries',
          builder: (context, state) => const DiscoveriesScreen(),
        ),
        GoRoute(
          path: '/history',
          builder: (context, state) => const HistoryScreen(),
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
    )),
  );
  // Kroky navigace do "černé skříňky" (diagnostika zamrzání).
  router.routerDelegate.addListener(() {
    diagNote('route ${router.routerDelegate.currentConfiguration.uri}');
  });
  // iOS: Ovládací centrum / upozornění Shazamu otevírají obrazovky přes nativní most.
  NativeNav.attach(router);
  // Restart appky (přepnutí profilu) staví nový router -- starý uvolnit.
  ref.onDispose(() {
    NativeNav.detach(router);
    router.dispose();
  });
  return router;
});

/// go_router 14.8.1 při `push` detailu záložky nad stránkou MIMO záložky
/// (`/shazam`, `/tuner`, `/wrapped/…`, `/playlist-join/…`, přehrávač nad
/// nimi) přidá druhou kopii celého `StatefulShellRoute` (viz
/// `RouteMatchList._createNewMatchUntilIncompatible`: porovnává jen poslední
/// trasu) -- dvakrát tentýž GlobalKey navigátoru a pád. Takové stránky se
/// proto nejdřív sundají a detail se otevře v záložce pod nimi (zpět pak
/// vede v záložce, jako u každého detailu).
class _AppRouter extends GoRouter {
  _AppRouter({required super.routingConfig, super.initialLocation}) : super.routingConfig();

  @override
  Future<T?> push<T extends Object?>(String location, {Object? extra}) {
    final trimmed = _withoutOverlays(location);
    if (trimmed == null) return super.push<T>(location, extra: extra);
    return _pushOver<T>(trimmed, location, extra);
  }

  @override
  Future<T?> pushReplacement<T extends Object?>(String location, {Object? extra}) {
    final trimmed = _withoutOverlays(location);
    if (trimmed == null) return super.pushReplacement<T>(location, extra: extra);
    // Nahrazovaná stránka je mezi sundanými -- stačí obyčejný push.
    return _pushOver<T>(trimmed, location, extra);
  }

  Future<T?> _pushOver<T>((RouteMatchList, List<RouteMatchBase>) trimmed, String location, Object? extra) {
    final (base, removed) = trimmed;
    final result = routeInformationProvider.push<T>(location, base: base, extra: extra);
    // Kdo čekal na výsledek sundané stránky, nesmí viset navždy.
    for (final m in removed) {
      if (m is ImperativeRouteMatch && !m.completer.isCompleted) m.complete();
    }
    return result;
  }

  /// Současná konfigurace bez stránek nad záložkami -- jen když jsou nějaké
  /// a cíl patří do záložek (jinak `null` = běžný push).
  (RouteMatchList, List<RouteMatchBase>)? _withoutOverlays(String location) {
    final current = routerDelegate.currentConfiguration;
    final matches = current.matches;
    final shell = matches.indexWhere((m) => m is ShellRouteMatch);
    if (shell < 0 || shell == matches.length - 1) return null;
    final uri = Uri.parse(location);
    final target = configuration.findMatch(Uri.parse(branchRedirect(uri) ?? location));
    if (target.isError || target.matches.firstOrNull is! ShellRouteMatch) return null;
    final removed = matches.sublist(shell + 1);
    var base = current;
    for (final m in removed.reversed) {
      base = base.remove(m);
    }
    return (base, removed);
  }
}

/// Detaily, které se otevírají uvnitř záložky (viz `branches.dart`) -- každá
/// záložka je má jako podstránky, takže tab bar zůstává a historie se drží
/// zvlášť pro každou záložku.
List<RouteBase> _detailRoutes() => [
      GoRoute(
        path: 'podcasts/history',
        builder: (context, state) => const PodcastHistoryScreen(),
      ),
      GoRoute(
        path: 'podcasts/show/:showId',
        builder: (context, state) => PodcastShowScreen(showId: state.pathParameters['showId']!),
      ),
      GoRoute(
        path: 'spoken/book/:bookId',
        builder: (context, state) => SpokenBookScreen(bookId: state.pathParameters['bookId']!),
      ),
      GoRoute(
        path: 'franchise/:franchiseId',
        builder: (context, state) => FranchiseScreen(franchiseId: state.pathParameters['franchiseId']!),
      ),
      GoRoute(
        path: 'games/list/:listId',
        builder: (context, state) => GamesListScreen(base: 'games', listId: state.pathParameters['listId']!),
      ),
      GoRoute(
        path: 'movies/list/:listId',
        builder: (context, state) => GamesListScreen(base: 'movies', listId: state.pathParameters['listId']!),
      ),
      GoRoute(
        path: 'artists/:artistId',
        builder: (context, state) => ArtistScreen(artistId: state.pathParameters['artistId']!),
      ),
      GoRoute(
        path: 'artists/:artistId/discography',
        builder: (context, state) => ArtistDiscographyScreen(
          artistId: state.pathParameters['artistId']!,
          initialType: state.uri.queryParameters['type'] ?? 'all',
        ),
      ),
      GoRoute(path: 'blends', builder: (context, state) => const BlendScreen()),
      // „Poslat v Opentify" -- poslaná skladba (features/share).
      GoRoute(
        path: 'track/:recordingId',
        builder: (context, state) => TrackLinkScreen(recordingId: state.pathParameters['recordingId']!),
      ),
      GoRoute(
        path: 'releases/:releaseId',
        builder: (context, state) => ReleaseScreen(
          releaseId: state.pathParameters['releaseId']!,
          highlightTrackId: state.uri.queryParameters['track'],
        ),
      ),
      GoRoute(
        path: 'browse/tag/:tag',
        builder: (context, state) => TagScreen(tag: state.pathParameters['tag']!),
      ),
      GoRoute(
        path: 'browse/:categoryId',
        builder: (context, state) => BrowseCategoryScreen(categoryId: state.pathParameters['categoryId']!),
      ),
      GoRoute(
        path: 'later',
        builder: (context, state) => const ListenLaterScreen(),
      ),
      GoRoute(
        path: 'shared',
        builder: (context, state) => const SharedPlaylistsScreen(),
      ),
      GoRoute(
        path: 'shazam-list',
        builder: (context, state) => const ShazamCollectionScreen(),
      ),
      GoRoute(
        path: 'liked',
        builder: (context, state) => const LikedSongsScreen(),
      ),
      GoRoute(
        path: 'playlists/:playlistId',
        builder: (context, state) => PlaylistDetailScreen(playlistId: state.pathParameters['playlistId']!),
      ),
      GoRoute(
        path: 'verify-downloads',
        builder: (context, state) => const VerifyDownloadsScreen(),
      ),
      GoRoute(
        path: 'playback-test',
        builder: (context, state) => const PlaybackTestScreen(),
      ),
      GoRoute(
        path: 'year-in-review',
        builder: (context, state) => const YearInReviewScreen(),
      ),
    ];
