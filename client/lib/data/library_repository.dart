import '../core/api_client.dart';
import '../core/media_url.dart';
import '../models/playlist_model.dart';
import '../models/recording_model.dart';
import 'playlists_repository.dart' show PlaylistSummaryModel;

/// Stránkovaný výsledek `GET /library/local-tracks`.
class LocalTracksPage {
  const LocalTracksPage({required this.total, required this.items});

  final int total;
  final List<RecordingModel> items;

  factory LocalTracksPage.fromJson(Map<String, dynamic> json) => LocalTracksPage(
        total: json['total'] as int,
        items: (json['items'] as List<dynamic>)
            .map((e) => RecordingModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Album seskupené z lokální knihovny (`GET /library/local-albums`).
class LocalAlbum {
  const LocalAlbum({
    required this.id,
    required this.title,
    this.coverImageUrl,
    required this.artistId,
    required this.artistName,
    required this.trackCount,
    this.addedAt,
    this.totalTracks,
    this.complete = false,
  });

  final String id;
  final String title;
  final String? coverImageUrl;
  final String artistId;
  final String artistName;
  final int trackCount;

  /// Kolik skladeb album má (z tracklistu); `null` = zatím neznámé.
  final int? totalTracks;

  /// V knihovně jsou všechny skladby alba ("Jen celá alba").
  final bool complete;

  /// Kdy album přibylo do knihovny (ISO) -- řazení „Přidáno".
  final String? addedAt;

  factory LocalAlbum.fromJson(Map<String, dynamic> json) => LocalAlbum(
        id: json['id'] as String,
        title: json['title'] as String,
        coverImageUrl: resolveMediaUrl(json['coverImageUrl'] as String?),
        artistId: json['artistId'] as String,
        artistName: json['artistName'] as String,
        trackCount: json['trackCount'] as int,
        addedAt: json['addedAt'] as String?,
        totalTracks: json['totalTracks'] as int?,
        complete: json['complete'] as bool? ?? false,
      );
}

/// Interpret seskupený z lokální knihovny (`GET /library/local-artists`).
class LocalArtist {
  const LocalArtist({required this.id, required this.name, this.imageUrl, required this.trackCount, this.addedAt});

  final String id;
  final String name;
  final String? imageUrl;
  final int trackCount;
  final String? addedAt;

  factory LocalArtist.fromJson(Map<String, dynamic> json) => LocalArtist(
        id: json['id'] as String,
        name: json['name'] as String,
        imageUrl: resolveMediaUrl(json['imageUrl'] as String?),
        trackCount: json['trackCount'] as int,
        addedAt: json['addedAt'] as String?,
      );
}

/// Žánr napříč lokální knihovnou (`GET /library/genres`) -- MusicBrainz
/// genre tagy na albech, viz backend `CatalogService._enrich_release_genres`.
class LocalGenre {
  const LocalGenre({required this.genre, required this.trackCount});

  final String genre;
  final int trackCount;

  factory LocalGenre.fromJson(Map<String, dynamic> json) => LocalGenre(
        genre: json['genre'] as String,
        trackCount: json['trackCount'] as int,
      );
}

/// Průběh skenu (`POST /library/scan` ho jen odstartuje na pozadí --
/// MusicBrainz limituje na 1 request/s, takže tisíce souborů by se v jednom
/// HTTP requestu nestihly, viz backend `app/library/scanner.py`).
/// `GET /library/scan/status` se pak pravidelně dotazuje na skutečný stav.
class LibraryScanStatus {
  const LibraryScanStatus({
    required this.status,
    required this.root,
    required this.totalFiles,
    required this.scanned,
    required this.matchedMusicbrainz,
    required this.matchedLocal,
    required this.alreadyScanned,
    required this.skippedNoTags,
    required this.errors,
    this.errorMessage,
  });

  final String status; // idle | running | done | error
  final String root;
  final int totalFiles;
  final int scanned;
  final int matchedMusicbrainz;
  final int matchedLocal;
  final int alreadyScanned;
  final int skippedNoTags;
  final int errors;
  final String? errorMessage;

  bool get isRunning => status == 'running';
  int get matchedTotal => matchedMusicbrainz + matchedLocal;

  factory LibraryScanStatus.fromJson(Map<String, dynamic> json) => LibraryScanStatus(
        status: json['status'] as String,
        root: json['root'] as String? ?? '',
        totalFiles: json['totalFiles'] as int? ?? 0,
        scanned: json['scanned'] as int? ?? 0,
        matchedMusicbrainz: json['matchedMusicbrainz'] as int? ?? 0,
        matchedLocal: json['matchedLocal'] as int? ?? 0,
        alreadyScanned: json['alreadyScanned'] as int? ?? 0,
        skippedNoTags: json['skippedNoTags'] as int? ?? 0,
        errors: json['errors'] as int? ?? 0,
        errorMessage: json['errorMessage'] as String?,
      );
}

/// Výsledek `POST /library/import/spotify` -- ZIP s CSV playlisty
/// (Exportify apod.) i `YourLibrary.json` (oficiální Spotify export).
class SpotifyImportResult {
  const SpotifyImportResult({
    required this.totalInFile,
    required this.matched,
    required this.alreadyPresent,
    required this.skipped,
    required this.playlistsImported,
    this.playlists = const [],
  });

  final int totalInFile;
  final int matched;
  final int alreadyPresent;
  final int skipped;
  final int playlistsImported;
  final List<ImportedPlaylistReport> playlists;

  factory SpotifyImportResult.fromJson(Map<String, dynamic> json) => SpotifyImportResult(
        totalInFile: json['totalInFile'] as int,
        matched: json['matched'] as int,
        alreadyPresent: json['alreadyPresent'] as int,
        skipped: json['skipped'] as int,
        playlistsImported: json['playlistsImported'] as int? ?? 1,
        playlists: (json['playlists'] as List<dynamic>? ?? const [])
            .map((e) => ImportedPlaylistReport.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Jeden playlist z importu -- `inLibrary` = kolik jeho skladeb už jde
/// rovnou přehrát (zbytek se obstará při prvním přehrání).
class ImportedPlaylistReport {
  const ImportedPlaylistReport({
    required this.id,
    required this.title,
    required this.total,
    required this.matched,
    required this.skipped,
    required this.inLibrary,
  });

  final String id;
  final String title;
  final int total;
  final int matched;
  final int skipped;
  final int inLibrary;

  factory ImportedPlaylistReport.fromJson(Map<String, dynamic> json) => ImportedPlaylistReport(
        id: json['id'] as String,
        title: json['title'] as String,
        total: json['total'] as int,
        matched: json['matched'] as int,
        skipped: json['skipped'] as int,
        inLibrary: json['inLibrary'] as int,
      );
}

/// Výsledek `GET /library/search` -- hledání jen v obsahu knihovny, bez
/// diakritiky (viz backend `routes/library.py:search_library`).
class LibrarySearchResult {
  const LibrarySearchResult({
    required this.query,
    required this.tracks,
    required this.albums,
    required this.artists,
    required this.playlists,
  });

  final String query;
  final List<RecordingModel> tracks;
  final List<LocalAlbum> albums;
  final List<LocalArtist> artists;
  final List<PlaylistSummaryModel> playlists;

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;

  factory LibrarySearchResult.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) parse) =>
        (json[key] as List<dynamic>? ?? const []).map((e) => parse(e as Map<String, dynamic>)).toList();
    return LibrarySearchResult(
      query: json['query'] as String? ?? '',
      tracks: list('tracks', RecordingModel.fromJson),
      albums: list('albums', LocalAlbum.fromJson),
      artists: list('artists', LocalArtist.fromJson),
      playlists: list('playlists', PlaylistSummaryModel.fromJson),
    );
  }
}

/// Tenká vrstva nad `/library/*` (docs/openapi.yaml) — sken lokální hudební
/// knihovny a import Spotify "Liked Songs" exportu.
class LibraryRepository {
  LibraryRepository(this._api);

  final ApiClient _api;

  /// Jen odstartuje sken na pozadí -- pro průběh viz [scanStatus].
  Future<void> startScan() async {
    await _api.postJson('/library/scan');
  }

  Future<LibraryScanStatus> scanStatus() async {
    final json = await _api.getJson('/library/scan/status');
    return LibraryScanStatus.fromJson(json);
  }

  /// Playlisty/knihovna, NEBO historie poslechů (ZIP "Extended streaming
  /// history" -- server ho pozná sám; pak `historyListens`).
  Future<({SpotifyImportResult? result, int? historyListens, int? libraryTracks, String? platform})> importSpotifyLibrary(
      List<int> bytes, String filename) async {
    final json = await _api.postMultipart(
      '/library/import/spotify',
      fieldName: 'file',
      bytes: bytes,
      filename: filename,
    );
    if (json['kind'] == 'history') {
      return (
        result: null,
        historyListens: json['listens'] as int? ?? 0,
        libraryTracks: json['libraryTracks'] as int?,
        platform: json['platform'] as String?,
      );
    }
    return (result: SpotifyImportResult.fromJson(json), historyListens: null, libraryTracks: null, platform: null);
  }

  Future<LibrarySearchResult> searchLibrary(String query, {int limit = 20}) async {
    final json = await _api.getJson('/library/search', query: {'q': query, 'limit': '$limit'});
    return LibrarySearchResult.fromJson(json);
  }

  /// "Odebrat z knihovny" -- `dryRun` jen spočítá, co by se stalo (pro
  /// potvrzovací sheet), nic nemění.
  Future<LibraryRemovalResult> removeTracks(List<String> recordingIds, {bool dryRun = false}) async {
    final json = await _api.postJson(
      '/library/tracks/remove${dryRun ? '?dryRun=true' : ''}',
      body: {'recordingIds': recordingIds},
    );
    return LibraryRemovalResult.fromJson(json);
  }

  Future<PlaylistDetailModel> likedSongs() async {
    final json = await _api.getJson('/library/liked-songs');
    return PlaylistDetailModel.fromJson(json);
  }

  Future<void> likeSong(String recordingId) async {
    await _api.postJson('/library/liked-songs/$recordingId');
  }

  Future<void> unlikeSong(String recordingId) async {
    await _api.deleteJson('/library/liked-songs/$recordingId');
  }

  /// Zlomené srdce (backend app/library/dislikes.py).
  Future<Set<String>> dislikedIds() async {
    final json = await _api.getJson('/library/disliked');
    return (json['recordingIds'] as List<dynamic>).cast<String>().toSet();
  }

  Future<void> dislikeSong(String recordingId) async {
    await _api.postJson('/library/disliked/$recordingId');
  }

  Future<void> undislikeSong(String recordingId) async {
    await _api.deleteJson('/library/disliked/$recordingId');
  }

  /// Naskenované lokální soubory (`POST /library/scan`) -- vždy `available`,
  /// takže je jde v klientu rovnou přehrát bez obstarávání.
  Future<LocalTracksPage> localTracks({int limit = 100, int offset = 0}) async {
    final json = await _api.getJson('/library/local-tracks', query: {'limit': '$limit', 'offset': '$offset'});
    return LocalTracksPage.fromJson(json);
  }

  /// Stejná knihovna seskupená po albech -- jeden dotaz na backendu, ne
  /// N+1 z klienta (viz `routes/library.py::local_albums`).
  Future<List<LocalAlbum>> localAlbums() async {
    final json = await _api.getJsonList('/library/local-albums');
    return json.map((e) => LocalAlbum.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<LocalArtist>> localArtists() async {
    final json = await _api.getJsonList('/library/local-artists');
    return json.map((e) => LocalArtist.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Žánry napříč lokální knihovnou, řídké dokud se knihovna neprojde/nedoplní
  /// (žánry se doplňují líně při otevření alba, viz backend) -- pohání
  /// "Podle nálady a žánru" na Home.
  Future<List<LocalGenre>> genres() async {
    final json = await _api.getJsonList('/library/genres');
    return json.map((e) => LocalGenre.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<LocalTracksPage> tracksByGenre(String genre) async {
    final json = await _api.getJson('/library/by-genre/${Uri.encodeComponent(genre)}');
    return LocalTracksPage.fromJson(json);
  }

  /// Skladby interpretů s MusicBrainz `country == "CZ"` -- pohání "Česká
  /// hudba" na Home.
  Future<LocalTracksPage> czechMusic() async {
    final json = await _api.getJson('/library/czech');
    return LocalTracksPage.fromJson(json);
  }
}


/// Výsledek (nebo náhled) odebrání z knihovny.
class LibraryRemovalResult {
  const LibraryRemovalResult({required this.removed, required this.freedBytes, required this.deleted, required this.hidden});

  final int removed;
  final int freedBytes;

  /// Stažené soubory -- smažou se a uvolní místo.
  final int deleted;

  /// Soubory z uživatelovy vlastní složky -- jen se skryjí, nic se nemaže.
  final int hidden;

  factory LibraryRemovalResult.fromJson(Map<String, dynamic> json) {
    final results = (json['results'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    return LibraryRemovalResult(
      removed: json['removed'] as int? ?? 0,
      freedBytes: json['freedBytes'] as int? ?? 0,
      deleted: results.where((r) => r['result'] == 'deleted').length,
      hidden: results.where((r) => r['result'] == 'hidden').length,
    );
  }
}

String formatMegabytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1).replaceAll('.', ',')} MB';
}
