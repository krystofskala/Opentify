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
      status == 'STREAMING' ||
      status == 'TRANSCODING' ||
      status == 'PENDING' ||
      status == 'RUNNING';

  bool get isAvailable => status == 'AVAILABLE' || status == 'SUCCEEDED';
  bool get isFailed => status == 'FAILED';

  /// Lidsky čitelný popisek pro `PlayerBar`/`NowPlayingScreen`, ať je při
  /// čekání na `track.available` vidět, že appka fakt něco dělá (obstarává
  /// soubor), ne jen generický "buffering" spinner nerozeznatelný od
  /// zaseknuté appky -- jediné místo, kde se `status` mapuje na text.
  String get statusLabel => switch (status) {
        'REQUESTING' || 'QUEUED' || 'PENDING' => 'Ve frontě…',
        'DOWNLOADING' || 'RUNNING' => pct != null ? 'Stahuji… $pct %' : 'Stahuji…',
        // Přehrává se, i když stahování ještě běží na pozadí -- viz
        // `TrackStreamingEvent`/`AudioPlayerController._playCurrent`.
        'STREAMING' => pct != null ? 'Přehrávám a stahuji… $pct %' : 'Přehrávám a stahuji…',
        'TRANSCODING' => 'Zpracovávám…',
        _ => 'Připravuji…',
      };

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

  /// Korekce hlasitosti per `recordingId` (viz `AudioPlayerController`'s
  /// normalizace) -- plní se z odpovědi `provision()` (cache hit) nebo
  /// dodatečně přes `fetchLoudnessGain`. Mimo `state`, ať se kvůli ní
  /// zbytečně nepřestavuje UI všech `TrackTile`ů.
  final Map<String, double> _loudnessGains = {};

  double? loudnessGainFor(String recordingId) => _loudnessGains[recordingId];

  Future<double?> fetchLoudnessGain(String recordingId) async {
    final cached = _loudnessGains[recordingId];
    if (cached != null) return cached;
    try {
      final gain = await _repo.loudnessGain(recordingId);
      if (gain != null) _loudnessGains[recordingId] = gain;
      return gain;
    } catch (_) {
      return null; // normalizace je jen bonus -- výpadek nesmí nic rozbít
    }
  }

  TrackProvisioningState stateFor(String recordingId, Availability catalogAvailability) {
    return state[recordingId] ??
        TrackProvisioningState(
          status: catalogAvailability == Availability.available ? 'AVAILABLE' : null,
        );
  }

  Future<void> provision(String recordingId, {bool interactive = false}) async {
    _update(recordingId, (s) => s.copyWith(status: 'REQUESTING'));
    try {
      final result = await _repo.provision(recordingId, interactive: interactive);
      if (result.job != null) {
        _jobIdToRecordingId[result.job!.id] = recordingId;
      }
      if (result.loudnessGainDb != null) {
        _loudnessGains[recordingId] = result.loudnessGainDb!;
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
      case TrackStreamingEvent():
        // Zachovává `jobId`/`pct` z dosavadního stavu (`copyWith`) -- na
        // rozdíl od `TrackAvailableEvent` tohle NENÍ konec provisioningu,
        // `job.progress` bude ještě chvíli chodit dál.
        _update(
          event.recordingId,
          (s) => s.copyWith(status: 'STREAMING', streamUrl: event.streamUrl),
        );
      case JobProgressEvent():
        final recordingId = _jobIdToRecordingId[event.jobId];
        if (recordingId == null) return; // job z jiného zařízení/session, nesledujeme ho
        _update(
          recordingId,
          // `job.progress` dál chodí i po `track.streaming` -- nenech
          // BĚŽNÉ tiky (RUNNING/PENDING) přepsat `STREAMING` zpátky na
          // "Stahuji", jinak by `statusLabel`/ikonka blikaly při každém
          // procentu. `FAILED` (a cokoliv jiného) musí projít VŽDY -- jinak
          // by neúspěšné dokončení po selhaném progresivním přehrání
          // (viz `AudioPlayerController._handleStreamFailure`) zůstalo
          // navěky "zaseknuté" na STREAMING, i když job už dávno selhal.
          (s) {
            final keepStreaming =
                s.status == 'STREAMING' && (event.status == 'RUNNING' || event.status == 'PENDING');
            return s.copyWith(status: keepStreaming ? null : event.status, pct: event.pct);
          },
        );
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
