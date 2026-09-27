import '../core/api_client.dart';
import '../models/playlist_model.dart';

/// Výsledek `POST /library/scan` — kolik souborů se v `MUSIC_DIR` našlo a
/// jak dopadlo párování na katalog (viz backend `app/library/scanner.py`).
class LibraryScanResult {
  const LibraryScanResult({
    required this.root,
    required this.scanned,
    required this.matched,
    required this.skippedNoTags,
    required this.errors,
  });

  final String root;
  final int scanned;
  final int matched;
  final int skippedNoTags;
  final int errors;

  factory LibraryScanResult.fromJson(Map<String, dynamic> json) => LibraryScanResult(
        root: json['root'] as String,
        scanned: json['scanned'] as int,
        matched: json['matched'] as int,
        skippedNoTags: json['skippedNoTags'] as int,
        errors: json['errors'] as int,
      );
}

/// Výsledek `POST /library/import/spotify`.
class SpotifyImportResult {
  const SpotifyImportResult({
    required this.totalInFile,
    required this.matched,
    required this.alreadyLiked,
    required this.skipped,
  });

  final int totalInFile;
  final int matched;
  final int alreadyLiked;
  final int skipped;

  factory SpotifyImportResult.fromJson(Map<String, dynamic> json) => SpotifyImportResult(
        totalInFile: json['totalInFile'] as int,
        matched: json['matched'] as int,
        alreadyLiked: json['alreadyLiked'] as int,
        skipped: json['skipped'] as int,
      );
}

/// Tenká vrstva nad `/library/*` (docs/openapi.yaml) — sken lokální hudební
/// knihovny a import Spotify "Liked Songs" exportu.
class LibraryRepository {
  LibraryRepository(this._api);

  final ApiClient _api;

  Future<LibraryScanResult> scan() async {
    final json = await _api.postJson('/library/scan');
    return LibraryScanResult.fromJson(json);
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
}
