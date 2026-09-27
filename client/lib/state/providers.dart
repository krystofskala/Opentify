import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/realtime_event.dart';
import '../core/ws_client.dart';
import '../data/catalog_repository.dart';
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
