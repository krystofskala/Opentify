import '../core/api_client.dart';
import '../core/media_url.dart';
import 'listen_later_repository.dart';

/// Výsledek Open Shazamu (backend `POST /recognize`).
class RecognizeResult {
  const RecognizeResult({required this.found, this.title, this.artist, this.album, this.coverUrl, this.item});

  final bool found;
  final String? title;
  final String? artist;
  final String? album;
  final String? coverUrl;

  /// Položka v "Poslechnout později" (se značkou Open Shazam).
  final LaterItem? item;

  factory RecognizeResult.fromJson(Map<String, dynamic> j) => RecognizeResult(
        found: j['found'] == true,
        title: j['title'] as String?,
        artist: j['artist'] as String?,
        album: j['album'] as String?,
        coverUrl: resolveMediaUrl(j['coverUrl'] as String?),
        item: j['item'] == null ? null : LaterItem.fromJson(j['item'] as Map<String, dynamic>),
      );
}

class RecognizeRepository {
  RecognizeRepository(this._api);

  final ApiClient _api;

  Future<RecognizeResult> recognize(List<int> bytes, String mimeType) async {
    final ext = mimeType.contains('mp4') ? 'm4a' : (mimeType.contains('ogg') ? 'ogg' : 'webm');
    final json = await _api.postMultipart('/recognize', fieldName: 'file', bytes: bytes, filename: 'clip.$ext');
    return RecognizeResult.fromJson(json);
  }
}
