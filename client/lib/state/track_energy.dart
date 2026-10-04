import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_player_controller.dart';
import 'glass_settings.dart';
import 'providers.dart';

/// Obrys hlasitosti skladby (`GET /tracks/{id}/waveform`): úrovně 0..1
/// stejně dlouhých úseků od začátku do konce. Pozadí "Nové" podle něj jemně
/// dýchá -- žádná analýza zvuku za běhu, funguje i na iPhonu. `null` =
/// ještě neměřeno (pozadí pak jen bez dýchání).
typedef TrackLevels = ({List<double> levels, double mean, int durationMs});

final trackLevelsProvider = FutureProvider.autoDispose.family<TrackLevels?, String>((ref, recordingId) async {
  try {
    final json = await ref.watch(apiClientProvider).getJson('/tracks/$recordingId/waveform');
    final raw = (json['buckets'] as List<dynamic>? ?? const []).cast<num>();
    final duration = (json['durationMs'] as num?)?.toInt();
    if (raw.isEmpty || duration == null || duration <= 0) return null;
    final levels = [for (final v in raw) v / 255.0];
    final mean = levels.fold<double>(0, (a, v) => a + v) / levels.length;
    return (levels: levels, mean: mean, durationMs: duration);
  } catch (_) {
    return null;
  }
});

/// Úroveň právě hrající skladby jen když je zapnuté pozadí "Nové".
final currentTrackLevelsProvider = Provider<TrackLevels?>((ref) {
  if (!ref.watch(backgroundV2Provider)) return null;
  final id = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId));
  if (id == null) return null;
  return ref.watch(trackLevelsProvider(id)).valueOrNull;
});

/// Hlasitost v daném místě skladby vůči jejímu průměru (-1..1, 0 = průměr),
/// lineárně mezi úseky.
double levelAt(TrackLevels data, Duration position) {
  final n = data.levels.length;
  final x = (position.inMilliseconds / data.durationMs * n - 0.5).clamp(0.0, n - 1.0);
  final i = x.floor();
  final j = (i + 1).clamp(0, n - 1);
  final v = data.levels[i] + (data.levels[j] - data.levels[i]) * (x - i);
  final range = data.mean < 0.5 ? data.mean : 1 - data.mean;
  return ((v - data.mean) / (range <= 0 ? 1 : range)).clamp(-1.0, 1.0);
}
