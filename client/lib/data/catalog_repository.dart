import '../core/api_client.dart';
import '../models/artist_bio_model.dart';
import '../models/discography_model.dart';
import '../models/artist_model.dart';
import '../models/release_model.dart';
import '../models/recording_model.dart';
import '../models/search_result.dart';

/// Tenká vrstva nad `/catalog/*` (docs/openapi.yaml) — jen HTTP volání +
/// deserializace, žádná byznys logika (ta žije na backendu v CatalogService).
class CatalogRepository {
  CatalogRepository(this._api);

  final ApiClient _api;

  Future<CatalogSearchResult> search(
    String query, {
    String? entityType,
    int limit = 20,
    int offset = 0,
  }) async {
    final json = await _api.getJson('/catalog/search', query: {
      'q': query,
      if (entityType != null) 'type': entityType,
      'limit': '$limit',
      'offset': '$offset',
    });
    return CatalogSearchResult.fromJson(json);
  }

  Future<ArtistModel> getArtist(String artistId) async {
    final json = await _api.getJson('/catalog/artists/$artistId');
    return ArtistModel.fromJson(json);
  }

  Future<ArtistBioModel> getArtistBio(String artistId) async {
    final json = await _api.getJson('/catalog/artists/$artistId/bio');
    return ArtistBioModel.fromJson(json);
  }

  /// Odkazy "Podpořit umělce" (web, Bandcamp, obchod, Discogs, koncerty).
  Future<Map<String, dynamic>> getArtistSupport(String artistId) =>
      _api.getJson('/catalog/artists/$artistId/support');

  Future<DiscographyModel> getDiscography(String artistId, {String? releaseType}) async {
    final json = await _api.getJson(
      '/catalog/artists/$artistId/discography',
      query: releaseType == null ? null : {'releaseType': releaseType},
    );
    return DiscographyModel.fromJson(json);
  }

  /// Nevydané a vzácné nahrávky (dema, živáky, bootlegy) -- může trvat
  /// několik sekund (MusicBrainz), volá se líně až pod diskografií.
  Future<List<({ReleaseModel release, String rarity})>> getRarities(String artistId) async {
    final json = await _api.getJson('/catalog/artists/$artistId/rarities');
    return (json['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map((e) => (release: ReleaseModel.fromJson(e), rarity: e['rarity'] as String? ?? 'live'))
        .toList();
  }

  Future<ReleaseModel> getRelease(String releaseId) async {
    final json = await _api.getJson('/catalog/releases/$releaseId');
    return ReleaseModel.fromJson(json);
  }

  Future<RecordingModel> getRecording(String recordingId) async {
    final json = await _api.getJson('/catalog/recordings/$recordingId');
    return RecordingModel.fromJson(json);
  }

  Future<List<RecordingModel>> getReleaseTracks(String releaseId) async {
    final json = await _api.getJsonList('/catalog/releases/$releaseId/tracks');
    return json.map((e) => RecordingModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Nejposlouchanější skladby interpreta s `listenCount` (ListenBrainz),
  /// nebo pořadí oblíbenosti z Deezeru bez počtů.
  Future<List<RecordingModel>> getArtistTopTracks(String artistId) async {
    final json = await _api.getJsonList('/catalog/artists/$artistId/top-tracks');
    return json.map((e) => RecordingModel.fromJson(e as Map<String, dynamic>)).toList();
  }
}
