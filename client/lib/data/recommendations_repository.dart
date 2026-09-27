import '../core/api_client.dart';
import '../models/playlist_model.dart';
import '../models/recording_model.dart';

/// Tenká vrstva nad `/recommendations/*` (docs/openapi.yaml). Backend vrací
/// pro obojí prázdný výsledek, když ListenBrainz instance neběží/nemá pro
/// uživatele ještě vygenerované playlisty (cold start) — to se v UI
/// zobrazuje jako prázdný stav, ne jako chyba (viz features/home/home_screen.dart).
class RecommendationsRepository {
  RecommendationsRepository(this._api);

  final ApiClient _api;

  Future<List<RecordingModel>> discover({int limit = 20}) async {
    final json = await _api.getJsonList('/recommendations/discover', query: {'limit': '$limit'});
    return json.map((e) => RecordingModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PlaylistDetailModel> dailyJams() async {
    final json = await _api.getJson('/recommendations/daily-jams');
    return PlaylistDetailModel.fromJson(json);
  }
}
