import '../core/api_client.dart';
import '../core/media_url.dart';
import '../models/playlist_model.dart';

/// Souhrn playlistu pro seznamovou obrazovku (`GET /playlists`) -- bez
/// `items`, na rozdíl od `PlaylistDetailModel` (`GET /playlists/{id}`),
/// který appka používá i pro Daily Jams/Liked Songs.
class PlaylistSummaryModel {
  const PlaylistSummaryModel({
    required this.id,
    required this.title,
    required this.kind,
    this.source,
    required this.itemCount,
    this.coverUrls = const [],
    this.artistNames = const [],
  });

  final String id;
  final String title;
  final String kind;
  final String? source;
  final int itemCount;

  /// Až 4 různé obaly pro mozaiku (jako karty na Domů).
  final List<String> coverUrls;

  /// Nejčastější interpreti v playlistu (max 3) -- do podtitulku.
  final List<String> artistNames;

  factory PlaylistSummaryModel.fromJson(Map<String, dynamic> json) => PlaylistSummaryModel(
        id: json['id'] as String,
        title: json['title'] as String,
        kind: json['kind'] as String,
        source: json['source'] as String?,
        itemCount: json['itemCount'] as int,
        coverUrls: resolveMediaUrls((json['coverUrls'] as List<dynamic>? ?? const []).cast<String>()),
        artistNames: (json['artistNames'] as List<dynamic>? ?? const []).cast<String>(),
      );
}

/// Tenká vrstva nad `/playlists/*` (backend `routes/playlists.py`) -- obecné
/// CRUD nad VLASTNÍMI playlisty uživatele. Liked Songs/Daily Jams mají svoje
/// vlastní repository (`LibraryRepository`/`RecommendationsRepository`),
/// tenhle je jen pro playlisty, co si uživatel sám založí a pojmenuje.
class PlaylistsRepository {
  PlaylistsRepository(this._api);

  final ApiClient _api;

  Future<List<PlaylistSummaryModel>> list() async {
    final json = await _api.getJsonList('/playlists');
    return json.map((e) => PlaylistSummaryModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PlaylistDetailModel> create(String title) async {
    final json = await _api.postJson('/playlists', body: {'title': title});
    return PlaylistDetailModel.fromJson(json);
  }

  Future<PlaylistDetailModel> get(String playlistId) async {
    final json = await _api.getJson('/playlists/$playlistId');
    return PlaylistDetailModel.fromJson(json);
  }

  /// "Přidat do knihovny" -- vlastní kopie žebříčku/mixu z Domů.
  Future<PlaylistDetailModel> copy(String playlistId) async {
    final json = await _api.postJson('/playlists/$playlistId/copy');
    return PlaylistDetailModel.fromJson(json);
  }

  Future<void> delete(String playlistId) async {
    await _api.deleteJson('/playlists/$playlistId');
  }

  Future<PlaylistDetailModel> addItem(String playlistId, String recordingId) async {
    final json = await _api.postJson('/playlists/$playlistId/items', body: {'recording_id': recordingId});
    return PlaylistDetailModel.fromJson(json);
  }

  Future<PlaylistDetailModel> removeItem(String playlistId, String recordingId) async {
    final json = await _api.deleteJson('/playlists/$playlistId/items/$recordingId');
    return PlaylistDetailModel.fromJson(json!);
  }

  /// Kompletní nové pořadí `recordingId`s -- server vyžaduje přesnou
  /// permutaci současných položek (viz `routes/playlists.py:reorder_items`).
  Future<PlaylistDetailModel> reorderItems(String playlistId, List<String> recordingIds) async {
    final json = await _api.patchJson(
      '/playlists/$playlistId/items/reorder',
      body: {'recording_ids': recordingIds},
    );
    return PlaylistDetailModel.fromJson(json);
  }
}
