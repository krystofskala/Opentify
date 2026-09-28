import '../core/api_client.dart';

/// Hlášení poslechů (scrobbling) -- server je uloží do historie pro osobní
/// mixy a přepošle do ListenBrainz.
class ListensRepository {
  const ListensRepository(this._api);

  final ApiClient _api;

  Future<void> submitListen({
    required String recordingId,
    required DateTime playedAt,
    required Duration played,
    String? source,
    String? context,
  }) async {
    await _api.postJson('/listens', body: {
      'recordingId': recordingId,
      'playedAt': playedAt.toUtc().toIso8601String(),
      'durationPlayedMs': played.inMilliseconds,
      if (source != null) 'source': source,
      if (context != null) 'context': context,
    });
  }

  Future<void> playingNow(String recordingId) async {
    await _api.postJson('/listens/playing-now', body: {'recordingId': recordingId});
  }
}
