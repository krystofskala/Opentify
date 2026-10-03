import 'dart:async';

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
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) => _checkStalled());
  }

  // Pojistka proti propásnuté WS zprávě (iOS spojení na pozadí přeruší):
  // skladba pak navždy "stahovala" na 0 % a u řádku nebylo nic, pomohl až
  // restart appky (živě nahlášeno). Když se stav stahované skladby přes
  // `_stallAfter` nezměnil, zeptat se serveru přes REST (provision je
  // idempotentní -- existující job jen vrátí, hotovou skladbu vrátí jako
  // AVAILABLE). Max `_maxRechecks` pokusů na skladbu.
  static const _stallAfter = Duration(seconds: 10);
  static const _maxRechecks = 6;
  late final Timer _watchdog;
  final Map<String, DateTime> _lastChange = {};
  final Map<String, int> _rechecks = {};
  final Set<String> _checking = {};

  Future<void> _checkStalled() async {
    final now = DateTime.now();
    for (final entry in state.entries) {
      final id = entry.key;
      if (!entry.value.isInFlight || entry.value.status == 'STREAMING' || _checking.contains(id)) continue;
      final last = _lastChange[id];
      if (last == null || now.difference(last) < _stallAfter) continue;
      final count = _rechecks[id] ?? 0;
      if (count >= _maxRechecks) continue;
      _rechecks[id] = count + 1;
      _checking.add(id);
      try {
        final result = await _repo.provision(id);
        if (result.job != null) _jobIdToRecordingId[result.job!.id] = id;
        final job = result.job;
        final status = result.streamUrl != null ? 'AVAILABLE' : (job?.status ?? result.status);
        final current = state[id];
        // Změnilo se něco mezitím přes WS? Pak nepřepisovat.
        if (current != null && current.isInFlight) {
          _update(id, (s) => s.copyWith(status: status, streamUrl: result.streamUrl));
        }
      } catch (_) {
        // Síť -- zkusí se příště.
      } finally {
        _checking.remove(id);
      }
    }
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
      // `track.available` přes WS mohl přijít dřív než odpověď -- nepřepsat
      // hotovou skladbu zpátky na PENDING.
      if (state[recordingId]?.isAvailable == true && result.streamUrl == null) return;
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
            // STREAMING -> PENDING = stažení spadlo a server ho zkouší znovu
            // (worker retry): starý progresivní stream je mrtvý, zahodit ho.
            if (s.status == 'STREAMING' && event.status == 'PENDING') {
              return TrackProvisioningState(status: 'PENDING', jobId: s.jobId);
            }
            final keepStreaming = s.status == 'STREAMING' && event.status == 'RUNNING';
            return s.copyWith(status: keepStreaming ? null : event.status, pct: event.pct, error: event.error);
          },
        );
      case PlaybackStateEvent():
      case QueueUpdatedEvent():
      case QueueConflictEvent():
      case ConnectEvent():
      case UnknownEvent():
        break; // mimo scope provisioning controlleru, viz PlaybackController
    }
  }

  /// Po "Odebrat z knihovny" -- zapomenout lokální stav, ať skladba znovu
  /// vypadá jako nestažená (další přehrání ji stáhne znovu).
  void forget(String recordingId) {
    if (!state.containsKey(recordingId)) return;
    _loudnessGains.remove(recordingId);
    state = {...state}..remove(recordingId);
  }

  void _update(String recordingId, TrackProvisioningState Function(TrackProvisioningState) transform) {
    final current = state[recordingId] ?? const TrackProvisioningState.idle();
    final next = transform(current);
    if (next.status != current.status || next.pct != current.pct) {
      _lastChange[recordingId] = DateTime.now();
    }
    if (!next.isInFlight) _rechecks.remove(recordingId);
    state = {...state, recordingId: next};
  }

  @override
  void dispose() {
    _watchdog.cancel();
    _subscription.close();
    super.dispose();
  }
}

final provisioningControllerProvider =
    StateNotifierProvider<ProvisioningController, Map<String, TrackProvisioningState>>((ref) {
  return ProvisioningController(ref.watch(provisioningRepositoryProvider), ref);
});
