import '../core/api_client.dart';
import '../models/playlist_model.dart';
import '../models/recording_model.dart';

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
  });

  final String id;
  final String title;
  final String? coverImageUrl;
  final String artistId;
  final String artistName;
  final int trackCount;

  factory LocalAlbum.fromJson(Map<String, dynamic> json) => LocalAlbum(
        id: json['id'] as String,
        title: json['title'] as String,
        coverImageUrl: json['coverImageUrl'] as String?,
        artistId: json['artistId'] as String,
        artistName: json['artistName'] as String,
        trackCount: json['trackCount'] as int,
      );
}

/// Interpret seskupený z lokální knihovny (`GET /library/local-artists`).
class LocalArtist {
  const LocalArtist({required this.id, required this.name, this.imageUrl, required this.trackCount});

  final String id;
  final String name;
  final String? imageUrl;
  final int trackCount;

  factory LocalArtist.fromJson(Map<String, dynamic> json) => LocalArtist(
        id: json['id'] as String,
        name: json['name'] as String,
        imageUrl: json['imageUrl'] as String?,
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
  });

  final int totalInFile;
  final int matched;
  final int alreadyPresent;
  final int skipped;
  final int playlistsImported;

  factory SpotifyImportResult.fromJson(Map<String, dynamic> json) => SpotifyImportResult(
        totalInFile: json['totalInFile'] as int,
        matched: json['matched'] as int,
        alreadyPresent: json['alreadyPresent'] as int,
        skipped: json['skipped'] as int,
        playlistsImported: json['playlistsImported'] as int? ?? 1,
      );
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

  Future<SpotifyImportResult> importSpotifyLibrary(List<int> bytes, String filename) async {
    final json = await _api.postMultipart(
      '/library/import/spotify',
      fieldName: 'file',
      bytes: bytes,
      filename: filename,
    );
    return SpotifyImportResult.fromJson(json);
  }

  Future<PlaylistDetailModel> likedSongs() async {
    final json = await _api.getJson('/library/liked-songs');
    return PlaylistDetailModel.fromJson(json);
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
}
