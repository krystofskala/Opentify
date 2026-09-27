import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/realtime_event.dart';
import '../data/provisioning_repository.dart';
import '../models/availability.dart';
import 'providers.dart';

/// Odvozený stav jedné nahrávky v provisioning pipeline -- `status` sleduje
/// buď `MediaAssetStatus` (z REST odpovědi) nebo `ProvisioningJobStatus`
/// (z `job.progress` WS eventu); obojí backend používá jako string, klient
/// je nerozlišuje, protože UI z nich chce jen "co ukázat uživateli".
class TrackProvisioningState {
  const TrackProvisioningState({this.status, this.jobId, this.pct, this.streamUrl, this.error});

  const TrackProvisioningState.idle() : this();

  final String? status;
  final String? jobId;
  final int? pct;
  final String? streamUrl;
  final String? error;

  bool get isInFlight => status == 'REQUESTING' ||
      status == 'QUEUED' ||
      status == 'DOWNLOADING' ||
      status == 'TRANSCODING' ||
      status == 'PENDING' ||
      status == 'RUNNING';

  bool get isAvailable => status == 'AVAILABLE' || status == 'SUCCEEDED';
  bool get isFailed => status == 'FAILED';

  /// `error` se (na rozdíl od ostatních polí) nikdy nedědí ze starého stavu —
  /// každý nový `copyWith` volaný z reakce na REST/WS update znamená "něco
  /// se posunulo", takže stará chybová hláška by tam jen strašila navíc.
  TrackProvisioningState copyWith({String? status, String? jobId, int? pct, String? streamUrl, String? error}) {
    return TrackProvisioningState(
      status: status ?? this.status,
      jobId: jobId ?? this.jobId,
      pct: pct ?? this.pct,
      streamUrl: streamUrl ?? this.streamUrl,
      error: error,
    );
  }
}

/// Drží provisioning stav per `recordingId` a aktualizuje ho reaktivně na
/// `TrackAvailableEvent`/`JobProgressEvent` z WS -- to je ten "aktualizace
/// stavů skladeb po příjmu WebSocket zpráv" požadavek ze zadání. REST
/// (`ProvisioningRepository.provision`) jen spustí flow a dá první stav;
/// zbytek přijde přes `RealtimeClient.events`.
class ProvisioningController extends StateNotifier<Map<String, TrackProvisioningState>> {
  ProvisioningController(this._repo, Ref ref) : super({}) {
    _subscription = ref.listen<AsyncValue<RealtimeEvent>>(
      realtimeEventsProvider,
      (previous, next) => next.whenData(_handleEvent),
    );
  }

  final ProvisioningRepository _repo;
  late final ProviderSubscription<AsyncValue<RealtimeEvent>> _subscription;

  /// `job.progress` nese jen `jobId`, ne `recordingId` -- tahle mapa je
  /// jediné místo, které si drží spojení mezi nimi (naplní se při `provision`).
  final Map<String, String> _jobIdToRecordingId = {};

  TrackProvisioningState stateFor(String recordingId, Availability catalogAvailability) {
    return state[recordingId] ??
        TrackProvisioningState(
          status: catalogAvailability == Availability.available ? 'AVAILABLE' : null,
        );
  }

  Future<void> provision(String recordingId) async {
    _update(recordingId, (s) => s.copyWith(status: 'REQUESTING'));
    try {
      final result = await _repo.provision(recordingId);
      if (result.job != null) {
        _jobIdToRecordingId[result.job!.id] = recordingId;
      }
      _update(
        recordingId,
        (_) => TrackProvisioningState(
          status: result.status,
          jobId: result.job?.id,
          streamUrl: result.streamUrl,
        ),
      );
    } catch (e) {
      _update(recordingId, (s) => s.copyWith(status: 'FAILED', error: '$e'));
    }
  }

  void _handleEvent(RealtimeEvent event) {
    switch (event) {
      case TrackAvailableEvent():
        _update(
          event.recordingId,
          (_) => TrackProvisioningState(status: 'AVAILABLE', streamUrl: event.streamUrl),
        );
      case JobProgressEvent():
        final recordingId = _jobIdToRecordingId[event.jobId];
        if (recordingId == null) return; // job z jiného zařízení/session, nesledujeme ho
        _update(recordingId, (s) => s.copyWith(status: event.status, pct: event.pct));
      case PlaybackStateEvent():
      case QueueUpdatedEvent():
      case QueueConflictEvent():
      case UnknownEvent():
        break; // mimo scope provisioning controlleru, viz PlaybackController
    }
  }

  void _update(String recordingId, TrackProvisioningState Function(TrackProvisioningState) transform) {
    final current = state[recordingId] ?? const TrackProvisioningState.idle();
    state = {...state, recordingId: transform(current)};
  }

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

final provisioningControllerProvider =
    StateNotifierProvider<ProvisioningController, Map<String, TrackProvisioningState>>((ref) {
  return ProvisioningController(ref.watch(provisioningRepositoryProvider), ref);
});
