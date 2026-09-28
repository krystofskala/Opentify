import '../core/api_client.dart';

/// Jeden řádek synchronizovaného textu (LRC formát: `[mm:ss.xx]text`).
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;
}

class LyricsModel {
  const LyricsModel({this.plain, this.syncedLines, required this.instrumental});

  final String? plain;
  final List<LyricLine>? syncedLines;
  final bool instrumental;

  bool get hasSynced => syncedLines != null && syncedLines!.isNotEmpty;
  bool get hasAny => hasSynced || (plain != null && plain!.trim().isNotEmpty) || instrumental;
}

/// `GET /lyrics/{recordingId}` -- server-side proxy na veřejné LRCLIB (viz
/// `backend/app/lyrics_service.py`), stejně jako MusicBrainz/Deezer/
/// ListenBrainz nejdou z klienta napřímo.
class LyricsRepository {
  LyricsRepository(this._api);

  final ApiClient _api;

  Future<LyricsModel?> getLyrics(String recordingId) async {
    try {
      final json = await _api.getJson('/lyrics/$recordingId');
      final synced = json['synced'] as String?;
      return LyricsModel(
        plain: json['plain'] as String?,
        syncedLines: synced == null ? null : _parseLrc(synced),
        instrumental: json['instrumental'] as bool? ?? false,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  static final _lineRegex = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{1,3}))?\](.*)');

  List<LyricLine>? _parseLrc(String lrc) {
    final lines = <LyricLine>[];
    for (final raw in lrc.split('\n')) {
      final match = _lineRegex.firstMatch(raw);
      if (match == null) continue;
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3);
      final millis = fraction == null ? 0 : int.parse(fraction.padRight(3, '0').substring(0, 3));
      final text = match.group(4)!.trim();
      lines.add(LyricLine(Duration(minutes: minutes, seconds: seconds, milliseconds: millis), text));
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
