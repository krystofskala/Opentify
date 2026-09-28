import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/realtime_event.dart';
import '../core/ws_client.dart';
import '../data/listens_repository.dart';
import '../data/catalog_repository.dart';
import '../models/playlist_model.dart';
import '../data/home_repository.dart';
import '../data/library_repository.dart';
import '../data/lyrics_repository.dart';
import '../data/playlists_repository.dart';
import '../data/provisioning_repository.dart';
import '../data/recommendations_repository.dart';

/// Sdílený `ApiClient` -- jedna instance pro celou appku (connection reuse),
/// zavřená při dispose containeru (hot-restart v devu, ne v produkci).
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    baseUrl: AppConfig.apiBaseUrl,
    userId: AppConfig.userId,
    deviceId: AppConfig.deviceId,
  );
  ref.onDispose(client.close);
  return client;
});

final catalogRepositoryProvider = Provider<CatalogRepository>((ref) {
  return CatalogRepository(ref.watch(apiClientProvider));
});

final recommendationsRepositoryProvider = Provider<RecommendationsRepository>((ref) {
  return RecommendationsRepository(ref.watch(apiClientProvider));
});

final provisioningRepositoryProvider = Provider<ProvisioningRepository>((ref) {
  return ProvisioningRepository(ref.watch(apiClientProvider));
});

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  return HomeRepository(ref.watch(apiClientProvider));
});

/// Celá obrazovka Domů jedním voláním (`GET /home`, snapshoty v DB).
final homeProvider = FutureProvider.autoDispose<List<HomeSection>>((ref) {
  return ref.watch(homeRepositoryProvider).home();
});

/// Oblíbené skladby -- sdílené Knihovnou (karta + detail); dřív žily v Profilu.
final likedSongsProvider = FutureProvider.autoDispose<PlaylistDetailModel>((ref) {
  return ref.watch(libraryRepositoryProvider).likedSongs();
});

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return LibraryRepository(ref.watch(apiClientProvider));
});

final listensRepositoryProvider = Provider<ListensRepository>((ref) {
  return ListensRepository(ref.watch(apiClientProvider));
});

final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  return LyricsRepository(ref.watch(apiClientProvider));
});

final playlistsRepositoryProvider = Provider<PlaylistsRepository>((ref) {
  return PlaylistsRepository(ref.watch(apiClientProvider));
});

/// Seznam VLASTNÍCH playlistů uživatele -- sdílený mezi Knihovna tabem
/// ("Playlisty") a "Přidat do playlistu" sheetem (`widgets/add_to_playlist_sheet.dart`),
/// ať se po vytvoření/smazání playlistu obojí zdroj pravdy shodne po jednom
/// `ref.invalidate(myPlaylistsProvider)`, ne dvou nezávislých voláních API.
final myPlaylistsProvider = FutureProvider.autoDispose((ref) {
  return ref.watch(playlistsRepositoryProvider).list();
});

/// Jedno WS spojení pro celou appku -- playback i provisioning controller
/// poslouchají stejný `events` stream (viz core/ws_client.dart).
final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  final client = RealtimeClient(
    wsUrl: AppConfig.wsBaseUrl,
    userId: AppConfig.userId,
    deviceId: AppConfig.deviceId,
  );
  ref.onDispose(client.dispose);
  return client;
});

final realtimeEventsProvider = StreamProvider<RealtimeEvent>((ref) {
  return ref.watch(realtimeClientProvider).events;
});
