import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/realtime_event.dart';
import '../core/ws_client.dart';
import '../models/playback_model.dart';
import 'providers.dart';

/// Drží aktuální `PlaybackSession` (přehrávač + frontu) a je jediné místo,
/// které smí posílat `queue.set` -- řeší tím `expectedVersion` konflikt
/// popsaný v docs/asyncapi.yaml: `QueueSet.expectedVersion` musí sedět na
/// serverovou verzi, jinak přijde `queue.conflict` a je třeba to zopakovat
/// s aktuální verzí ze serveru (ne slepě inkrementovat lokálně).
///
/// Backend (app/realtime.py) `playback.*`/`queue.*` handling zatím reálně
/// neposílá/nezpracovává (jen TODO komentáře) -- kontroler je připraven na
/// celý protokol, ale dokud server nedoběhne, `state` zůstane na
/// `PlaybackSession.empty()` a měnit ho bude jen samotný klient lokálně.
class PlaybackController extends StateNotifier<PlaybackSession> {
  PlaybackController(this._realtime, Ref ref) : super(const PlaybackSession.empty()) {
    _subscription = ref.listen<AsyncValue<RealtimeEvent>>(
      realtimeEventsProvider,
      (previous, next) => next.whenData(_handleEvent),
    );
  }

  final RealtimeClient _realtime;
  late final ProviderSubscription<AsyncValue<RealtimeEvent>> _subscription;

  void _handleEvent(RealtimeEvent event) {
    switch (event) {
      case PlaybackStateEvent(session: final session):
        state = session;
      case QueueUpdatedEvent(queue: final queue, version: final version):
        state = state.copyWith(queue: queue, version: version);
      case QueueConflictEvent(currentQueue: final queue, currentVersion: final version):
        // Server odmítl náš `queue.set` -- přebíráme jeho pravdu. Volající
        // kód, který chtěl frontu změnit, musí svou změnu zopakovat nad
        // touhle novou verzí (retry je na něm, kontroler jen sesynchronizuje stav).
        state = state.copyWith(queue: queue, version: version);
      case TrackAvailableEvent():
      case JobProgressEvent():
      case UnknownEvent():
        break; // mimo scope playback controlleru, viz ProvisioningController
    }
  }

  void play(String recordingId, {int positionMs = 0}) {
    _realtime.playbackPlay(recordingId, positionMs: positionMs);
    state = state.copyWith(currentRecordingId: recordingId, positionMs: positionMs, isPlaying: true);
  }

  void pause() {
    _realtime.playbackPause();
    state = state.copyWith(isPlaying: false);
  }

  void seek(int positionMs) {
    _realtime.playbackSeek(positionMs);
    state = state.copyWith(positionMs: positionMs);
  }

  /// Nahradí celou frontu -- posílá se s *aktuální* verzí z lokálního stavu;
  /// pokud mezitím přišla novější verze odjinud, server odpoví `queue.conflict`
  /// a `_handleEvent` výše lokální stav dorovná na tu novější.
  void setQueue(List<QueueItem> queue) {
    _realtime.queueSet(queue, state.version);
  }

  void claimActiveDevice() => _realtime.claimActiveDevice();

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

final playbackControllerProvider = StateNotifierProvider<PlaybackController, PlaybackSession>((ref) {
  return PlaybackController(ref.watch(realtimeClientProvider), ref);
});
