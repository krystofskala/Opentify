import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/play_now_repository.dart';
import '../widgets/track_actions.dart' show nowPlayingInfoFor;
import 'audio_player_controller.dart';
import 'providers.dart';

/// Název fronty "Pusť teď" -- podle něj se pozná, že se má fronta doplňovat.
const playNowLabel = 'Pusť teď';

final playNowRepositoryProvider = Provider<PlayNowRepository>((ref) => PlayNowRepository(ref.watch(apiClientProvider)));

/// Doplňování fronty (plán P2):
/// - **Pusť teď** -- fronta spuštěná z dlaždice v Rychlém výběru se sama
///   doplňuje, dokud ji uživatel nevymění za jinou hudbu;
/// - **nekonečné hraní** (`RepeatMode.endless` na tlačítku opakování) --
///   když fronta dochází, naváže podobnou hudbou od toho, co hrálo.
/// Výchozí opakování je vždy vypnuté: konec fronty = konec.
final autoContinueProvider = Provider<AutoContinue>((ref) {
  final auto = AutoContinue(ref);
  ref.listen<AudioPlayerState>(audioPlayerControllerProvider, (_, next) => auto._onPlayer(next));
  return auto;
});

class AutoContinue {
  AutoContinue(this._ref);
  final Ref _ref;

  /// Nálada Pusť teď (`klid`, `energie`...); `null` = podle denní doby.
  String? mood;
  bool _loading = false;

  /// Po prázdné / neúspěšné várce se znovu ptá až po pauze (30 s, 2 min,
  /// 5 min) -- dřív šel další dotaz při každém posunu přehrávání a nový
  /// profil nebo výpadek Last.fm zahltil server (audit Pusť teď 7. 10.).
  DateTime? _retryAfter;
  int _failures = 0;
  static const _backoff = [Duration(seconds: 30), Duration(minutes: 2), Duration(minutes: 5)];

  void _failed() {
    _retryAfter = DateTime.now().add(_backoff[_failures.clamp(0, _backoff.length - 1)]);
    _failures++;
  }

  /// Profil bez dat: poslední `start` vrátil "zeptej se, z čeho začít".
  bool needsStart = false;

  // Okamžitá změna směru (audit C, schváleno 8. 10.): dvě přeskočení po sobě
  // v algoritmické frontě -> zbytek nachystané várky pryč a hned nová (server
  // pozná "jiný směr" z přeskočení). Dřív se změna projevila až za 8-10 skladeb.
  int? _lastIndex;
  String? _lastId;
  Duration _lastPos = Duration.zero;
  Duration? _lastDur;
  int _skipsInRow = 0;

  bool _wasSkip(AudioPlayerState s) {
    final dur = _lastDur;
    if (_lastIndex == null || s.queueIndex != _lastIndex! + 1 || dur == null || dur <= Duration.zero) return false;
    return _lastPos < dur * 0.5 && _lastPos < dur - const Duration(seconds: 10);
  }

  /// Spustí "Pusť teď" -- první várku hned, další se doplňují samy.
  /// `startArtistId` / `startRecordingId`: "Z čeho mám začít?" (profil bez dat).
  Future<String?> start({String? mood, String? startArtistId, String? startRecordingId}) async {
    this.mood = mood;
    _retryAfter = null;
    _failures = 0;
    final chunk = await _ref
        .read(playNowRepositoryProvider)
        .next(size: 10, mood: mood, startArtistId: startArtistId, startRecordingId: startRecordingId);
    needsStart = chunk.needsStart;
    if (chunk.tracks.isEmpty) return chunk.reason;
    final infos = [for (final r in chunk.tracks) nowPlayingInfoFor(r)];
    await _ref.read(audioPlayerControllerProvider.notifier).playQueue(infos, 0, sourceLabel: playNowLabel);
    return chunk.reason;
  }

  void _onPlayer(AudioPlayerState s) {
    if (s.nowPlaying == null || s.queue.isEmpty) return;
    final playNow = s.queueSourceLabel == playNowLabel;
    final endless = s.repeatMode == RepeatMode.endless;
    final id = s.nowPlaying!.recordingId;
    if (id != _lastId) {
      final skipped = (playNow || endless) && _wasSkip(s);
      _skipsInRow = skipped ? _skipsInRow + 1 : 0;
      _lastId = id;
      _lastIndex = s.queueIndex;
      _lastPos = Duration.zero;
      _lastDur = s.duration;
      if (_skipsInRow >= 2 && !_loading && !s.shuffleEnabled) {
        _skipsInRow = 0;
        unawaited(_turn(s, endless && !playNow));
        return;
      }
    } else {
      _lastPos = s.position;
      _lastDur = s.duration ?? _lastDur;
    }
    if (_loading) return;
    if (_retryAfter != null && DateTime.now().isBefore(_retryAfter!)) return;
    if (!playNow && !endless) return;
    final order = s.shuffleEnabled ? s.shuffleOrder : null;
    final remaining =
        order != null ? order.length - 1 - order.indexOf(s.queueIndex) : s.queue.length - 1 - s.queueIndex;
    if (remaining > 2) return;
    unawaited(_refill(s, endless && !playNow));
  }

  /// Jiný směr: nachystané skladby za právě hrající pryč a hned nová várka.
  Future<void> _turn(AudioPlayerState s, bool fromSeeds) async {
    final ctrl = _ref.read(audioPlayerControllerProvider.notifier);
    // Chvíli počkat, ať server dostane obě přeskočení (PlayEvent).
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final now = _ref.read(audioPlayerControllerProvider);
    if (now.queueSourceLabel != s.queueSourceLabel || now.nowPlaying?.recordingId != s.nowPlaying?.recordingId) return;
    for (var i = now.queue.length - 1; i > now.queueIndex; i--) {
      ctrl.removeFromQueue(i);
    }
    await _refill(_ref.read(audioPlayerControllerProvider), fromSeeds);
  }

  Future<void> _refill(AudioPlayerState s, bool fromSeeds) async {
    _loading = true;
    try {
      final ids = [for (final i in s.queue) i.recordingId];
      final chunk = await _ref.read(playNowRepositoryProvider).next(
            // Nekonečné hraní navazuje na poslední skladby fronty.
            seedIds: fromSeeds ? ids.sublist(ids.length > 3 ? ids.length - 3 : 0) : const [],
            playedIds: ids,
            size: 8,
            mood: fromSeeds ? null : mood,
          );
      if (chunk.tracks.isEmpty) {
        _failed();
        return;
      }
      _retryAfter = null;
      _failures = 0;
      final current = _ref.read(audioPlayerControllerProvider);
      // Mezitím jiná hudba / vypnuté nekonečno -> nic nepřidávat.
      if (current.queueSourceLabel != s.queueSourceLabel ||
          (fromSeeds && current.repeatMode != RepeatMode.endless)) {
        return;
      }
      await _ref
          .read(audioPlayerControllerProvider.notifier)
          .addAllToQueue([for (final r in chunk.tracks) nowPlayingInfoFor(r)], sourceLabel: s.queueSourceLabel);
    } catch (e) {
      _failed();
      debugPrint('AutoContinue: doplnění fronty selhalo: $e');
    } finally {
      _loading = false;
    }
  }
}
