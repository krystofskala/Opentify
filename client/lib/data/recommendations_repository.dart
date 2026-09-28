import '../core/api_client.dart';
import '../models/playlist_model.dart';
import '../models/recording_model.dart';
import '../models/year_in_review_model.dart';

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

  /// Sitewide žebříček veřejné komunity ListenBrainz, ne dat téhle instance
  /// (server sám poslechy nesleduje) -- viz backend `RecommendationService.trending`.
  Future<List<RecordingModel>> trending({int limit = 20, String range = 'week'}) async {
    final json = await _api.getJsonList('/recommendations/trending', query: {'limit': '$limit', 'range': range});
    return json.map((e) => RecordingModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Nejposlouchanější nahrávky nastaveného účtu (LISTENBRAINZ_USERNAME)
  /// přímo z jeho statistik -- funguje, i když ještě nemá vygenerované
  /// Daily Jams/Objevuj (ty čekají na dávkově počítaný troi patch).
  Future<List<RecordingModel>> myTopTracks({int limit = 20, String range = 'month'}) async {
    final json = await _api.getJsonList('/recommendations/my-top', query: {'limit': '$limit', 'range': range});
    return json.map((e) => RecordingModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Top nahrávky uživatelů s podobným vkusem na veřejném ListenBrainz --
  /// prázdné, dokud LISTENBRAINZ_USERNAME není skutečný účet s historií.
  Future<List<RecordingModel>> communityPicks({int limit = 20}) async {
    final json = await _api.getJsonList('/recommendations/community', query: {'limit': '$limit'});
    return json.map((e) => RecordingModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// "Rok v hudbě" -- top skladby/interpreti + celkový počet poslechů za
  /// poslední rok, viz `YearInReviewModel` docstring pro přesnost okna.
  Future<YearInReviewModel> yearInReview({int limit = 10}) async {
    final json = await _api.getJson('/recommendations/year-in-review', query: {'limit': '$limit'});
    return YearInReviewModel.fromJson(json);
  }
}
