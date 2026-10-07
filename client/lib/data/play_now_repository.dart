import '../core/api_client.dart';
import '../models/recording_model.dart';

/// Várka skladeb pro "Pusť teď" / nekonečné hraní (backend app/home/play_now.py).
class PlayNowChunk {
  const PlayNowChunk({required this.tracks, required this.reason, this.needsStart = false});
  final List<RecordingModel> tracks;

  /// Profil bez poslechů i srdíček: appka se zeptá, z čeho začít.
  final bool needsStart;

  /// Jeden důvod pro celou várku ("Podle toho, co posloucháš v tuhle dobu"),
  /// nikdy u každé skladby.
  final String reason;
}

class PlayNowMood {
  const PlayNowMood(this.id, this.title);
  final String id;
  final String title;
}

class PlayNowRepository {
  PlayNowRepository(this._api);
  final ApiClient _api;

  Future<PlayNowChunk> next({
    List<String> seedIds = const [],
    List<String> playedIds = const [],
    int size = 8,
    String? mood,
    String? startArtistId,
    String? startRecordingId,
  }) async {
    final json = await _api.postJson('/home/play-now', body: {
      'seedIds': seedIds,
      'playedIds': playedIds,
      'size': size,
      if (mood != null) 'mood': mood,
      if (startArtistId != null) 'startArtistId': startArtistId,
      if (startRecordingId != null) 'startRecordingId': startRecordingId,
    }, timeout: const Duration(seconds: 40));
    return PlayNowChunk(
      tracks: [
        for (final t in (json['tracks'] as List<dynamic>? ?? const []))
          RecordingModel.fromJson(t as Map<String, dynamic>),
      ],
      reason: json['reason'] as String? ?? '',
      needsStart: json['needsStart'] as bool? ?? false,
    );
  }

  Future<List<PlayNowMood>> moods() async {
    final json = await _api.getJson('/home/play-now/moods');
    return [
      for (final m in (json['moods'] as List<dynamic>? ?? const []))
        PlayNowMood((m as Map<String, dynamic>)['id'] as String, m['title'] as String),
    ];
  }

  /// "Víc / míň takových" -- vrací novou hodnotu (−15..15).
  Future<double> feedback(String recordingId, {required bool more}) async {
    final json = await _api.postJson('/home/feedback', body: {
      'recordingId': recordingId,
      'direction': more ? 'more' : 'less',
    });
    return (json['delta'] as num?)?.toDouble() ?? 0;
  }

  /// "Proč tohle?" -- jen na vyžádání.
  Future<String> why(String recordingId) async {
    final json = await _api.getJson('/home/why/$recordingId');
    return json['reason'] as String? ?? '';
  }
}
