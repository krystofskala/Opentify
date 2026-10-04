import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/realtime_event.dart';
import '../core/ws_client.dart';
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
    // Po znovupřipojení WS (restart serveru, iOS na pozadí) mohly utéct
    // zprávy -- všechno rozestahované hned ověřit, nečekat na lhůtu.
    // (Provider se po přepnutí profilu vytváří znovu -> poslouchat i nový.)
    _clientSub = ref.listen<RealtimeClient>(
      realtimeClientProvider,
      (_, client) => client.addConnectListener(_resyncAll),
      fireImmediately: true,
    );
  }

  late final ProviderSubscription<RealtimeClient> _clientSub;

  /// Skladba, na kterou teď čeká přehrávač -- tu watchdog nikdy jen tak
  /// nezahodí (jinak by přehrávač točil kolečko navždy), ale ohlásí chybu.
  String? awaitedRecordingId;

  void _resyncAll() {
    for (final id in state.keys) {
      if (state[id]?.isInFlight == true) {
        _lastChange[id] = DateTime.fromMillisecondsSinceEpoch(0);
        _rechecks.remove(id);
      }
    }
  }

  // Pojistka proti propásnuté WS zprávě (iOS spojení na pozadí přeruší):
  // skladba pak navždy "stahovala" na 0 % a u řádku nebylo nic, pomohl až
  // restart appky (živě nahlášeno). Když se stav stahované skladby přes
  // `_stallAfter` nezměnil, zeptat se serveru přes REST (provision je
  // idempotentní -- existující job jen vrátí, hotovou skladbu vrátí jako
  // AVAILABLE). Max `_maxRechecks` pokusů na skladbu.
  static const _stallAfter = Duration(seconds: 10);
  static const _streamingStallAfter = Duration(seconds: 45);
  static const _maxRechecks = 6;
  static const _liveJobStatuses = {'PENDING', 'QUEUED', 'RUNNING'};
  late final Timer _watchdog;
  final Map<String, DateTime> _lastChange = {};
  final Map<String, int> _rechecks = {};
  final Set<String> _checking = {};

  Future<void> _checkStalled() async {
    final now = DateTime.now();
    for (final entry in state.entries.toList()) {
      final id = entry.key;
      if (!entry.value.isInFlight || _checking.contains(id)) continue;
      final last = _lastChange[id];
      // I "STREAMING" (hraje se během stahování): když dohrálo stahování a
      // zpráva utekla, zůstal by kroužek navždy -- jen s delší lhůtou.
      final stallAfter = entry.value.status == 'STREAMING' ? _streamingStallAfter : _stallAfter;
      if (last == null || now.difference(last) < stallAfter) continue;
      final count = _rechecks[id] ?? 0;
      if (count >= _maxRechecks) {
        if (id == awaitedRecordingId) {
          // Přehrávač na ni čeká -- místo věčného kolečka chyba s "Zkusit znovu".
          _update(id, (s) => TrackProvisioningState(status: 'FAILED', jobId: s.jobId, error: 'Stahování se zaseklo'));
          continue;
        }
        // Ani server neví nic nového -- zaseknutý stav zahodit (řádek je
        // zase normální, další klepnutí spustí stahování znovu).
        state = Map.of(state)..remove(id);
        _lastChange.remove(id);
        _rechecks.remove(id);
        continue;
      }
      _checking.add(id);
      try {
        final jobId = entry.value.jobId;
        if (jobId != null) {
          // Jen PŘEČÍST stav jobu -- POST /provision by po ztracené FAILED
          // zprávě tiše založil nový job a kolečko se točilo znovu.
          final job = await _repo.getJob(jobId);
          // Server hlásí živý job (dlouhá slskd fronta) -> to není zaseknutí,
          // nepočítat -- jinak by zdravé stahování po ~minutě skončilo chybou
          // "Stahování se zaseklo". Na opravdu visící job má backend vlastní
          // 40min timeout. Počítá se jen neznámý/nekonzistentní stav.
          // (Síťová chyba = výjimka se nepočítá taky.)
          if (!_liveJobStatuses.contains(job.status)) _rechecks[id] = count + 1;
          final current = state[id];
          if (current == null || !current.isInFlight) continue; // mezitím přes WS
          switch (job.status) {
            case 'SUCCEEDED':
              _update(id, (_) => TrackProvisioningState(status: 'AVAILABLE', streamUrl: '/api/v1/tracks/$id/stream'));
            case 'FAILED' || 'CANCELLED':
              _update(id, (s) => TrackProvisioningState(status: 'FAILED', jobId: jobId, error: job.errorMessage ?? 'Stažení se nepodařilo'));
            default:
              _lastChange[id] = now; // pořád běží -- další kontrola za lhůtu
          }
        } else {
          final result = await _repo.provision(id);
          if (result.job != null) _jobIdToRecordingId[result.job!.id] = id;
          final job = result.job;
          final status = result.streamUrl != null ? 'AVAILABLE' : (job?.status ?? result.status);
          if (!_liveJobStatuses.contains(status)) _rechecks[id] = count + 1; // viz výš
          final current = state[id];
          // Změnilo se něco mezitím přes WS? Pak nepřepisovat.
          if (current != null && current.isInFlight) {
            _update(id, (s) => s.copyWith(status: status, jobId: job?.id, streamUrl: result.streamUrl));
          }
          // Další kontrola až za lhůtu -- se stejným stavem `_update` čas
          // neposune a POST by šel každých pár vteřin donekonečna.
          _lastChange[id] = now;
        }
      } catch (_) {
        // Síť -- zkusí se příště (nepočítá se do limitu).
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
    // Bez starého `streamUrl` (a chyby): přehrávač čekající v
    // `_waitForAvailability` by na něm jinak hned spustil stream starého
    // (mrtvého) pokusu dřív, než server odpoví.
    _update(recordingId, (s) => TrackProvisioningState(status: 'REQUESTING', jobId: s.jobId, pct: s.pct));
    try {
      final result = await _repo.provision(recordingId, interactive: interactive);
      if (result.job != null) {
        _jobIdToRecordingId[result.job!.id] = recordingId;
      }
      if (result.loudnessGainDb != null) {
        _loudnessGains[recordingId] = result.loudnessGainDb!;
      }
      // `track.available` přes WS mohl přijít dřív než odpověď -- nepřepsat
      // hotovou skladbu zpátky na PENDING; stejně tak běžící progresivní
      // stream (STREAMING) -- jen doplnit jobId.
      final now = state[recordingId];
      if (now?.isAvailable == true && result.streamUrl == null) return;
      if (now?.status == 'STREAMING' && result.streamUrl == null) {
        _update(recordingId, (s) => s.copyWith(jobId: result.job?.id));
        return;
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
      // Mezitím (WS/watchdog) se stav posunul dál -> pozdní chyba ho nepřepíše.
      if (state[recordingId]?.status != 'REQUESTING') return;
      _update(recordingId, (s) => s.copyWith(status: 'FAILED', error: _humanError(e)));
    }
  }

  static String _humanError(Object e) {
    final text = '$e';
    if (e is TimeoutException || text.contains('Timeout')) return 'Server neodpovídá, zkus to znovu';
    if (text.contains('SocketException') || text.contains('ClientException') || text.contains('XMLHttpRequest')) {
      return 'Bez spojení se serverem';
    }
    return 'Stahování se nepodařilo spustit';
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
            // Konečné selhání: starý progresivní `streamUrl` pryč, jinak by
            // přehrávač zkoušel mrtvý stream dokola a chyba by se neukázala.
            if (event.status == 'FAILED' || event.status == 'CANCELLED') {
              return TrackProvisioningState(status: 'FAILED', jobId: s.jobId, error: event.error ?? 'Stažení se nepodařilo');
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
    _clientSub.close();
    super.dispose();
  }
}

final provisioningControllerProvider =
    StateNotifierProvider<ProvisioningController, Map<String, TrackProvisioningState>>((ref) {
  return ProvisioningController(ref.watch(provisioningRepositoryProvider), ref);
});
