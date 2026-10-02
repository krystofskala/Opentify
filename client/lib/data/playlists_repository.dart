import '../core/api_client.dart';
import '../core/media_url.dart';
import '../models/playlist_model.dart';
import '../models/recording_model.dart';

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
    this.description,
    this.updatedAt,
    this.pinned = false,
    this.collab = false,
    this.member = false,
    this.ownerName,
  });

  /// Naposledy změněno (ISO) -- řazení „Přidáno / upraveno".
  final String? updatedAt;

  /// U sdílených ze Spotify "Ze Spotify · autor".
  final String? description;

  /// Naimportované z odkazu na Spotify (záložka Sdílené v Knihovně).
  bool get isShared => (source?.startsWith('spotify-link:') ?? false) || (source?.startsWith('apple-link:') ?? false) ||
      (source?.startsWith('youtube-link:') ?? false) ||
      (source?.startsWith('soundcloud-link:') ?? false);

  /// Playlist z tvé staré vlastní hudby (výběry, soundtracky) -- značka
  /// "před 2016" na náhledu.
  bool get isLegacy => source == 'own-music:legacy';

  /// Automatický mix připnutý do Knihovny -- dál se aktualizuje.
  final bool pinned;

  /// Společný playlist (sdílený s dalšími profily); `ownerName` u cizího.
  final bool collab;

  /// Jsem v cizím společném playlistu jen člen.
  final bool member;
  final String? ownerName;

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
        description: json['description'] as String?,
        updatedAt: json['updatedAt'] as String?,
        pinned: json['pinned'] as bool? ?? false,
        collab: json['collab'] as bool? ?? false,
        member: json['member'] as bool? ?? false,
        ownerName: json['ownerName'] as String?,
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

  /// Odkaz na Spotify playlist/album/skladbu -> playlist v knihovně
  /// (backend stáhne obsah přes VPN, viz `app/library/spotify_link.py`).
  Future<SpotifyLinkImport> importSpotifyLink(String url) async {
    final json = await _api.postJson(
      '/library/import/spotify-link',
      body: {'url': url},
      timeout: const Duration(minutes: 3),
    );
    if (json['kind'] == 'track') {
      final rec = json['recording'];
      return SpotifyLinkImport.track(rec == null ? null : RecordingModel.fromJson(rec as Map<String, dynamic>));
    }
    return SpotifyLinkImport(
      id: json['id'] as String,
      title: json['title'] as String,
      owner: json['owner'] as String?,
      total: json['total'] as int,
      matched: json['matched'] as int,
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  Future<PlaylistDetailModel> get(String playlistId) async {
    final json = await _api.getJson('/playlists/$playlistId');
    return PlaylistDetailModel.fromJson(json);
  }

  /// "Přidat do knihovny" -- vlastní kopie žebříčku/mixu z Domů.
  Future<void> pin(String playlistId) => _api.postJson('/playlists/$playlistId/pin');

  Future<void> unpin(String playlistId) => _api.deleteJson('/playlists/$playlistId/pin');

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

/// Výsledek importu z odkazu na Spotify.
class SpotifyLinkImport {
  const SpotifyLinkImport({
    required this.id,
    required this.title,
    this.owner,
    required this.total,
    required this.matched,
    required this.truncated,
  }) : recording = null;

  /// Odkaz na jednu skladbu -- nic se neukládá, jen se pustí.
  const SpotifyLinkImport.track(this.recording)
      : id = '',
        title = '',
        owner = null,
        total = 1,
        matched = 1,
        truncated = false;

  final RecordingModel? recording;
  bool get isTrack => id.isEmpty;

  final String id;
  final String title;
  final String? owner;
  final int total;
  final int matched;

  /// Spotify dává veřejně jen prvních 100 skladeb playlistu.
  final bool truncated;
}

/// Je v textu odkaz na Spotify nebo Apple Music (playlist, album, skladba)?
bool looksLikeSpotifyLink(String text) =>
    RegExp(r'^\s*(https?://)?(open\.spotify\.com/(intl-[a-z-]+/)?(playlist|album|track)/|spotify\.link/|spotify:(playlist|album|track):|music\.apple\.com/[a-z]{2}/(playlist|album|song)/|(www\.|m\.|music\.)?youtube\.com/(watch|playlist|shorts|live)|youtu\.be/|(www\.|m\.|on\.)?soundcloud\.com/)\S*\s*$')
        .hasMatch(text);
