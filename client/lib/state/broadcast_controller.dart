import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart' show ApiException;
import '../core/broadcast_sync.dart';
import '../core/config.dart';
import '../core/device_token.dart' show withDeviceToken, withoutDeviceToken;
import '../core/realtime_event.dart';
import '../core/ws_client.dart' show RealtimeClient;
import 'audio_player_controller.dart';
import 'providers.dart';

/// Sdílený stream ("Teď streamuje", poslouchej se mnou): vysílač posílá přes
/// Opentify Connect "co a kde hraje", posluchač hraje totéž sám ze serveru
/// a drží se vysílače (hodiny, kotvy, regulátor -- core/broadcast_sync.dart).
/// Server: backend app/broadcast.py. Návrh: 7y-sync-navrh.md (v3).

enum BroadcastRole { none, broadcasting, listening }

/// Živé vysílání v seznamu (jen jméno vysílače, skladba, počet posluchačů).
class LiveBroadcast {
  const LiveBroadcast({required this.id, required this.name, required this.mine, required this.isPlaying, this.recordingId, this.title, this.artist, this.artworkUrl, this.listeners = 0});

  final String id;
  final String name;
  final bool mine;
  final bool isPlaying;
  final String? recordingId;
  final String? title;
  final String? artist;
  final String? artworkUrl;
  final int listeners;

  factory LiveBroadcast.fromJson(Map<String, dynamic> j) {
    final t = j['track'] as Map<String, dynamic>?;
    return LiveBroadcast(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Někdo',
      mine: j['mine'] as bool? ?? false,
      isPlaying: j['isPlaying'] as bool? ?? false,
      recordingId: t?['recordingId'] as String?,
      title: t?['title'] as String?,
      artist: t?['artist'] as String?,
      // Obal z našeho serveru s tokenem TOHOTO zařízení (jako u Connect).
      artworkUrl: switch (t?['artworkUrl']) {
        final String url when url.startsWith(AppConfig.apiBaseUrl) => withDeviceToken(url),
        final String url => url,
        _ => null,
      },
      listeners: (j['listeners'] as num?)?.toInt() ?? 0,
    );
  }
}

class BroadcastState {
  const BroadcastState({
    this.role = BroadcastRole.none,
    this.sid,
    this.visibility = 'invited',
    this.listeners = 0,
    this.hostName,
    this.live = const [],
    this.ended,
    this.waiting = false,
    this.weakSync = false,
    this.notice,
    this.needsTap = false,
  });

  /// Posluchač: prohlížeč nepustil zvuk bez gesta -- ukázat "Klepni pro zvuk".
  final bool needsTap;

  final BroadcastRole role;
  final String? sid;
  final String visibility;

  /// Vysílač: kolik ho poslouchá.
  final int listeners;

  /// Posluchač: koho poslouchá.
  final String? hostName;
  final List<LiveBroadcast> live;

  /// Posluchač: vysílání skončilo (důvod) -- dohraje skladbu, nabídne návrat.
  final String? ended;

  /// Posluchač: čeká se na vysílač (restart serveru) nebo na první stav.
  final bool waiting;

  /// Posluchač: regulátor je ve volném režimu (slabé spojení).
  final bool weakSync;

  /// Krátké oznámení pro UI ("Vysílání převzalo jiné zařízení").
  final String? notice;

  BroadcastState copyWith({
    BroadcastRole? role,
    String? sid,
    String? visibility,
    int? listeners,
    String? hostName,
    List<LiveBroadcast>? live,
    String? ended,
    bool clearEnded = false,
    bool? waiting,
    bool? weakSync,
    String? notice,
    bool clearNotice = false,
    bool? needsTap,
  }) =>
      BroadcastState(
        role: role ?? this.role,
        sid: sid ?? this.sid,
        visibility: visibility ?? this.visibility,
        listeners: listeners ?? this.listeners,
        hostName: hostName ?? this.hostName,
        live: live ?? this.live,
        ended: clearEnded ? null : (ended ?? this.ended),
        waiting: waiting ?? this.waiting,
        weakSync: weakSync ?? this.weakSync,
        notice: clearNotice ? null : (notice ?? this.notice),
        needsTap: needsTap ?? this.needsTap,
      );
}

final broadcastProvider = StateNotifierProvider<BroadcastController, BroadcastState>((ref) {
  ref.watch(realtimeClientProvider); // nové spojení (jiný profil) -> nový controller
  return BroadcastController(ref);
});

/// Kolik položek fronty vysílač posílá dopředu (server bere max 500).
const _queueWindow = 200;

String _randomId() {
  final r = math.Random.secure();
  return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join(); // 128 bitů
}

class BroadcastController extends StateNotifier<BroadcastState> with WidgetsBindingObserver {
  BroadcastController(this._ref) : super(const BroadcastState()) {
    WidgetsBinding.instance.addObserver(this);
    final client = _ref.read(realtimeClientProvider);
    _client = client;
    _audioRef = _ref.read(audioPlayerControllerProvider.notifier);
    client.addConnectListener(_onConnected);
    _events = _ref.listen<AsyncValue<RealtimeEvent>>(realtimeEventsProvider, (_, next) {
      final event = next.valueOrNull;
      if (event is ConnectEvent) _onEvent(event);
    });
    if (client.isConnected) client.send('broadcasts.list', {});
    unawaited(_loadLatency());
  }

  // --- latence startu (play() -> zvuk), naučená a uložená v zařízení -------

  static const _latencyKey = 'broadcast.startLatency.v2';
  StartLatency _latency = StartLatency();

  Future<void> _loadLatency() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_latencyKey);
      if (raw != null) _latency = StartLatency(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  void _saveLatency() {
    final raw = jsonEncode(_latency.toJson());
    unawaited(SharedPreferences.getInstance().then((p) => p.setString(_latencyKey, raw)).then<void>((_) {}, onError: (Object _) {}));
  }

  /// Měření každého startu (bariéra, připravený start, přechod): latence
  /// z události přehrávače, chyba proti cíli 1,5 s po startu, záznam do
  /// diagnostiky a doučení odhadu (Kryštof 16. 10.).
  Map<String, Object?>? _startCheck;
  Timer? _startCheckTimer;

  void _expectStart(String kind, double tServer, {required bool local}) {
    final offset = clock.offsetMs;
    if (offset == null) return;
    final pred = _latency.estimate(local);
    _startCheck = {'kind': kind, 't': tServer, 'pred': pred, 'local': local, 'ev': null};
    final audio = _audio;
    audio.onStartMeasured = (ms, l) {
      final c = _startCheck;
      if (c != null && c['t'] == tServer) c['ev'] = ms;
    };
    _startCheckTimer?.cancel();
    final wait = tServer - offset - monoNowMs() + 1500;
    _startCheckTimer = Timer(Duration(milliseconds: wait.clamp(0, 30000).round()), () => _finishStart(tServer));
  }

  void _finishStart(double tServer) {
    final c = _startCheck;
    if (c == null || c['t'] != tServer || !mounted) return;
    _startCheck = null;
    final audio = _audio;
    final local = c['local'] as bool;
    final pred = c['pred'] as double;
    final ev = c['ev'] as double?;
    double? err;
    final now = monoNowMs();
    final serverNow = clock.serverNow(now);
    if (audio.sourceReady && audio.playerPlaying && serverNow != null) {
      if (state.role == BroadcastRole.listening && _model.anchor != null) {
        err = audio.exactPosition.inMicroseconds / 1000.0 - targetAt(_model.anchor!, serverNow, durationOf: _durationOf).positionMs;
      }
    }
    // Učit se z platformou nahlášeného startu; když chybí, ze zbytkové chyby
    // (zazní pozdě o d -> pozice o d pozadu -> skutečná latence = pred − err).
    final sample = ev ?? (err != null && err.abs() < 2000 ? pred - err : null);
    if (sample != null) {
      _latency.add(local, sample);
      _saveLatency();
    }
    final ePos = audio.lastPlaybackEvent;
    _diagEvent('START ${state.role == BroadcastRole.broadcasting ? 'B' : 'L'} kind=${c['kind']} plat=${defaultTargetPlatform.name} '
        'src=${local ? 'local' : 'stream'} pred=${_f(pred)} ev=${_f(ev)} err=${_f(err)} '
        'est=${_f(_latency.estimate(local))} p80=${_f(_latency.p80(local))} reload=${audio.startReloads} '
        'evPos=${ePos.updatePosition.inMilliseconds} evAge=${DateTime.now().difference(ePos.updateTime).inMilliseconds} ${_clockDiag()}');
  }

  final Ref _ref;
  late final ProviderSubscription<AsyncValue<RealtimeEvent>> _events;

  // Pro `dispose` (přepnutí profilu, odhlášení) -- `ref.read` tam už nejde.
  late final RealtimeClient _client;
  late final AudioPlayerController _audioRef;
  ProviderSubscription<AudioPlayerState>? _playerSub;

  final ClockSync clock = ClockSync();
  Timer? _clockTimer;
  Timer? _tick;
  Timer? _heartbeat;

  AudioPlayerController get _audio => _ref.read(audioPlayerControllerProvider.notifier);

  // --- společné: hodiny --------------------------------------------------

  void _onConnected() {
    if (!mounted) return;
    final client = _ref.read(realtimeClientProvider);
    client.send('broadcasts.list', {});
    if (state.role == BroadcastRole.none) return;
    // Nové spojení = hodiny znovu (restart API mění clockId) a stav znovu.
    clock.invalidate();
    _burst();
    if (state.role == BroadcastRole.broadcasting) {
      _sendStart();
    } else if (state.role == BroadcastRole.listening && state.sid != null && state.ended == null) {
      client.send('broadcast.join', {'sid': state.sid, 'prepMs': _prepMs()});
    }
  }

  /// Dávka 6 měření po 150 ms ("hodiny neplatné" -> platné).
  void _burst() {
    for (var i = 0; i < 6; i++) {
      Timer(Duration(milliseconds: 150 * i), _ping);
    }
  }

  void _ping() {
    final client = _ref.read(realtimeClientProvider);
    if (!client.isConnected) return;
    client.send('clock.ping', {'c0': monoNowMs()});
  }

  void _startClock() {
    _clockTimer?.cancel();
    _burst();
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) => _ping());
  }

  /// Vzorek hodin z HTTP odpovědi (WS na pozadí neběží).
  void _httpClockSample(double c0, Map<String, dynamic> body) {
    final s = (body['serverMs'] as num?)?.toDouble();
    final id = body['clockId'] as String?;
    if (s != null && id != null) clock.add(c0: c0, c1: monoNowMs(), s: s, clockId: id);
  }

  @override
  // ignore: avoid_renaming_method_parameters
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle != AppLifecycleState.resumed || state.role == BroadcastRole.none) return;
    // Monotónní čas na iOS/Androidu ve spánku stojí -- posun neplatí.
    clock.invalidate();
    _burst();
    _regulator.reset(monoNowMs());
    if (state.role == BroadcastRole.broadcasting) _sendAnchor(discontinuity: true);
  }

  void _onEvent(ConnectEvent e) {
    final p = e.payload;
    switch (e.type) {
      case 'clock.pong':
        final c0 = (p['c0'] as num?)?.toDouble();
        final s = (p['s'] as num?)?.toDouble();
        final id = p['clockId'] as String?;
        if (c0 != null && s != null && id != null) clock.add(c0: c0, c1: monoNowMs(), s: s, clockId: id);
      case 'broadcasts.update':
        final items = (p['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
        state = state.copyWith(live: [for (final i in items) LiveBroadcast.fromJson(i)]);
      case 'broadcast.started' || 'broadcast.listeners':
        if (p['sid'] != state.sid || state.role != BroadcastRole.broadcasting) return;
        final count = (p['count'] as num?)?.toInt() ?? (p['listeners'] as num?)?.toInt() ?? state.listeners;
        _listenerPrep = (p['prepMs'] as num?)?.toInt();
        final had = state.listeners;
        state = state.copyWith(listeners: count);
        if (count > 0 && had == 0) _sendAnchor(discontinuity: false);
        if (count == 0) _audio.cancelTransitionPlan();
      case 'broadcast.taken':
        if (p['sid'] == state.sid && state.role == BroadcastRole.broadcasting) {
          _stopBroadcasting(notice: 'Vysílání převzalo jiné zařízení.');
        }
      case 'broadcast.error':
        if (p['sid'] != state.sid) return;
        final status = (p['status'] as num?)?.toInt();
        if (state.role == BroadcastRole.broadcasting) {
          if (status == 409) _sendStart(); // server vysílání nezná (restart API)
          if (status == 410 || status == 403) _stopBroadcasting(notice: 'Vysílání skončilo.');
        }
      case 'broadcast.state':
        if (state.role == BroadcastRole.listening && p['sid'] == state.sid) _onListenerState(p);
      case 'broadcast.prepared':
        if (state.role == BroadcastRole.broadcasting && p['sid'] == state.sid) {
          _barrier.prepared((p['epoch'] as num).toInt());
          _maybeSendOwnReady();
        }
      case 'broadcast.added':
        if (state.role == BroadcastRole.broadcasting && p['sid'] == state.sid) _onAdded(p);
      case 'broadcast.add_result':
        final c = _addWaiting;
        _addWaiting = null;
        if (c != null && !c.isCompleted) c.complete(p['ok'] == true ? null : (p['reason'] as String? ?? 'Nepodařilo se přidat.'));
      case 'broadcast.prepare':
        if (state.role == BroadcastRole.listening && p['sid'] == state.sid) _onPrepare(p);
      case 'broadcast.go':
        if (p['sid'] != state.sid) return;
        if (state.role == BroadcastRole.broadcasting) {
          _onOwnerGo(p);
        } else if (state.role == BroadcastRole.listening) {
          p['solo'] == true ? _onSoloGo(p) : _onGroupGo(p);
        }
      case 'broadcast.pending':
        if (state.role == BroadcastRole.listening && p['sid'] == state.sid) {
          state = state.copyWith(waiting: true);
          _pendingSince ??= monoNowMs();
        }
      case 'broadcast.ended':
        if (state.role == BroadcastRole.listening && p['sid'] == state.sid) _onEnded(p['reason'] as String? ?? 'stopped');
    }
  }

  /// Seznam viditelných vysílání (Domů) -- i bez WS.
  Future<void> refreshList() async {
    try {
      final body = await _ref.read(apiClientProvider).getJson('/broadcasts');
      final items = (body['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
      state = state.copyWith(live: [for (final i in items) LiveBroadcast.fromJson(i)]);
    } catch (_) {}
  }

  /// Koho jde pozvat (stejné pravidlo jako Společný mix).
  Future<List<({String id, String name})>> inviteCandidates() async {
    final body = await _ref.read(apiClientProvider).getJson('/broadcasts/profiles');
    return [
      for (final i in (body['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
        (id: i['id'] as String, name: i['name'] as String? ?? '?'),
    ];
  }

  // --- vysílač -----------------------------------------------------------

  String? _bid;
  int _bseq = 0;
  int _epoch = 0;
  int _qv = 0;
  int _abs = 0;
  List<String> _invited = const [];
  int? _listenerPrep;
  String? _queueKey;
  String? _plannedFor;
  double? _transitionAtServer;
  double? _startAtServer;
  String? _startFor;
  Timer? _sendTimer;
  double _lastSend = -1e9;
  bool _sendQueueNext = false;
  bool _discontinuityNext = false;
  final LeadEstimate _loadLead = LeadEstimate(150);
  double _lastHttpBeat = -1e9;

  /// Skladba přidaná posluchačem: zařadit za poslední přidanou (organizátor
  /// ji pak může odebrat jako kteroukoli jinou).
  void _onAdded(Map<String, dynamic> p) {
    final item = p['item'] as Map<String, dynamic>?;
    final addId = p['addId'] as String?;
    if (item == null || addId == null || item['id'] is! String || item['t'] is! String) return;
    final s = _ref.read(audioPlayerControllerProvider);
    if (s.queue.isEmpty) return;
    final info = AudioPlayerController.queueItemFromJson(item)
        .withGroup(addGroupId(addId, item['byId'] as String? ?? ''), 'Přidal ${p['by'] ?? item['by'] ?? '?'}');
    final at = addInsertIndex([for (final q in s.queue) q.groupId], s.queueIndex);
    _audio.insertQueueItems(at, [info]);
  }

  // Ready bariéra: start po přeskoku, seek a play po pauze.
  final BarrierTracker _barrier = BarrierTracker();
  Timer? _prepareTimer;
  Timer? _goFallback;
  ({String kind, String rid, double positionMs})? _pendingPrepare;

  bool get canBroadcast {
    final s = _ref.read(audioPlayerControllerProvider);
    final np = s.nowPlaying;
    if (np == null || _audio.followingBroadcast) return false;
    // Mluvené slovo a lokální soubory z telefonu server nemá / nevysílá (MVP).
    return !np.recordingId.startsWith('sp:') && !np.recordingId.startsWith('pc:') && !np.recordingId.startsWith('local:');
  }

  /// Začít vysílat. `visibility`: `invited` (výchozí) nebo `server`.
  void startBroadcast({required String visibility, List<String> invited = const []}) {
    if (!canBroadcast || state.role != BroadcastRole.none) return;
    _bid = _randomId();
    _bseq = 0;
    _epoch = 1;
    _qv = 1;
    _abs = 0;
    _invited = invited;
    _queueKey = null;
    _prevState = null;
    _listenerPrep = null;
    _plannedFor = null;
    _transitionAtServer = null;
    _startAtServer = null;
    state = state.copyWith(role: BroadcastRole.broadcasting, sid: _randomId(), visibility: visibility, listeners: 0, clearEnded: true, clearNotice: true);
    _startClock();
    _audio.broadcastStartPlanner = _planStart;
    _audio.broadcastResumeBarrier = _resumeBarrier;
    _audio.broadcastSeekBarrier = _seekBarrier;
    _audio.onBarrierParked = _ownParked;
    _audio.onPlayBlocked = _onPlayBlocked;
    _audio.onSourceLoaded = (ms, cached) {
      _loadLead.add(ms);
      // Vlastní zdroj pro bariéru načtený a pozastavený na pozici = ready.
      final rid = _ref.read(audioPlayerControllerProvider).nowPlaying?.recordingId;
      if ((_barrier.active && rid == _barrier.recordingId) || (_pendingPrepare != null && rid == _pendingPrepare!.rid)) {
        _barrier.ownReady = true;
        _maybeSendOwnReady();
      }
    };
    _playerSub = _ref.listen<AudioPlayerState>(audioPlayerControllerProvider, _onPlayer);
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) => _sendAnchor(discontinuity: false));
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _broadcasterTick());
    _sendStart();
  }

  void stopBroadcast() => _stopBroadcasting();

  void _stopBroadcasting({String? notice}) {
    if (state.role != BroadcastRole.broadcasting) return;
    _diagFlush();
    final sid = state.sid;
    final bid = _bid;
    final client = _ref.read(realtimeClientProvider);
    if (client.isConnected) {
      client.send('broadcast.stop', {'sid': sid, 'bid': bid});
    } else {
      unawaited(_ref.read(apiClientProvider).postJson('/broadcast/stop', body: {'sid': sid, 'bid': bid}).then((_) {}, onError: (Object _) {}));
    }
    _teardown();
    state = BroadcastState(live: state.live, notice: notice);
  }

  void _teardown() {
    _playerSub?.close();
    _playerSub = null;
    _heartbeat?.cancel();
    _tick?.cancel();
    _clockTimer?.cancel();
    _sendTimer?.cancel();
    _pollActive = false;
    final audio = _audio;
    if (audio.broadcastStartPlanner == _planStart) audio.broadcastStartPlanner = null;
    audio.broadcastResumeBarrier = null;
    audio.broadcastSeekBarrier = null;
    audio.onBarrierParked = null;
    audio.onSourceLoaded = null;
    audio.cancelTransitionPlan();
    _prepareTimer?.cancel();
    _goFallback?.cancel();
    _barrier.clear();
    _pendingPrepare = null;
  }

  /// Fronta ve skutečném pořadí hraní od aktuální skladby (shuffle a
  /// "opakovat vše" rozbalené), nejvýš `_queueWindow` položek.
  List<NowPlayingInfo> _playOrder(AudioPlayerState s) {
    if (s.queue.isEmpty) return const [];
    if (s.repeatMode == RepeatMode.one) return [s.queue[s.queueIndex]];
    final order = (s.shuffleEnabled && s.shuffleOrder != null) ? s.shuffleOrder! : [for (var i = 0; i < s.queue.length; i++) i];
    final start = math.max(0, order.indexOf(s.queueIndex));
    final out = <NowPlayingInfo>[];
    for (var k = start; out.length < _queueWindow; k++) {
      if (k >= order.length) {
        if (s.repeatMode != RepeatMode.all) break;
        k = -1;
        continue;
      }
      out.add(s.queue[order[k]]);
      if (out.length >= order.length && s.repeatMode != RepeatMode.all) break;
    }
    return out;
  }

  Map<String, dynamic> _queuePayload() {
    final s = _ref.read(audioPlayerControllerProvider);
    return {
      'qv': _qv,
      'baseIndex': _abs,
      'items': [
        for (final q in _playOrder(s))
          {
            ...AudioPlayerController.queueItemToJson(q),
            // Přidaná posluchačem: kdo a které přidání (server podle toho
            // potvrdí a hlídá limit).
            if (parseAddGroupId(q.groupId) case final add?) ...{'addId': add.addId, 'byId': add.byId, 'by': (q.groupLabel ?? '').replaceFirst('Přidal ', '')},
            // Pole, která čte server pro seznam (karta "Teď streamuje").
            'recordingId': q.recordingId,
            'title': q.title,
            if (q.artistName != null) 'artistName': q.artistName,
            if (q.artworkUrl != null) 'artworkUrl': withoutDeviceToken(q.artworkUrl!),
          },
      ],
    };
  }

  String _queueIdentity(AudioPlayerState s) =>
      '${s.queue.length}|${s.queueIndex}|${s.shuffleEnabled}|${s.repeatMode.name}|${identityHashCode(s.queue)}|${identityHashCode(s.shuffleOrder)}';

  Map<String, dynamic> _anchorPayload() {
    final s = _ref.read(audioPlayerControllerProvider);
    final np = s.nowPlaying!;
    final mono = monoNowMs();
    final server = clock.serverNow(mono);
    final pos = _audio.sourceReady ? _audio.exactPosition.inMicroseconds / 1000.0 : s.position.inMilliseconds.toDouble();
    // Načítání / buffering: just_audio hlásí `playing`, ale zvuk nejde a pozice
    // stojí -- posluchač by ujel dopředu. Hraje = opravdu hraje.
    final playing = s.isPlaying && _audio.playerPlaying && !s.isBuffering && _audio.sourceReady;
    final planned = _startAtServer != null && _startFor == np.recordingId && server != null && server < _startAtServer! + 1500;
    return BroadcastAnchor(
      recordingId: np.recordingId,
      index: _abs,
      qv: _qv,
      epoch: _epoch,
      // Plánovaný start: oba začnou v `startAt` od pozice načtení.
      positionMs: planned && !playing ? s.position.inMilliseconds.toDouble() : pos,
      atServerMs: planned && !playing ? _startAtServer! : (server ?? mono),
      rate: s.speed,
      isPlaying: playing || planned,
      durationMs: s.duration?.inMilliseconds.toDouble(),
      repeatMode: s.repeatMode == RepeatMode.one ? 'one' : 'off',
      // Jen dokud se nerozjel -- pak už kotva nese změřenou pozici a čas.
      startAtServerMs: planned && !playing ? _startAtServer : null,
      transitionAtServerMs: _plannedFor == '${np.recordingId}|$_abs' ? _transitionAtServer : null,
      clockOk: server != null,
    ).toJson();
  }

  void _sendStart() {
    if (state.role != BroadcastRole.broadcasting || _ref.read(audioPlayerControllerProvider).nowPlaying == null) return;
    final body = {
      'sid': state.sid,
      'bid': _bid,
      'bseq': ++_bseq,
      'visibility': state.visibility,
      'invited': _invited,
      'deviceId': AppConfig.deviceId,
      'queue': _queuePayload(),
      'anchor': _anchorPayload(),
    };
    final client = _ref.read(realtimeClientProvider);
    if (client.isConnected) {
      client.send('broadcast.start', body);
    } else {
      unawaited(_httpPost('/broadcast/start', body));
    }
    _queueKey = _queueIdentity(_ref.read(audioPlayerControllerProvider));
  }

  /// Odeslat kotvu (a frontu, když se změnila) -- nejvýš 1× za 200 ms, poslední
  /// stav se pošle vždy (sloučení, nic se nezahodí).
  void _sendAnchor({required bool discontinuity, bool queue = false}) {
    if (state.role != BroadcastRole.broadcasting) return;
    if (discontinuity) _discontinuityNext = true;
    if (queue) _sendQueueNext = true;
    final wait = 200 - (monoNowMs() - _lastSend);
    if (wait > 0) {
      _sendTimer ??= Timer(Duration(milliseconds: wait.ceil()), () {
        _sendTimer = null;
        _flushSend();
      });
      return;
    }
    _flushSend();
  }

  void _flushSend() {
    if (state.role != BroadcastRole.broadcasting) return;
    // Běží bariéra: běžný stav by ji na serveru zrušil -- pošle se po `go`.
    if (_barrier.active || _pendingPrepare != null) return;
    final s = _ref.read(audioPlayerControllerProvider);
    if (s.nowPlaying == null) return;
    if (_discontinuityNext) _epoch++;
    _discontinuityNext = false;
    _lastSend = monoNowMs();
    final body = <String, dynamic>{
      'sid': state.sid,
      'bid': _bid,
      'bseq': ++_bseq,
      'anchor': _anchorPayload(),
      if (_sendQueueNext) 'queue': _queuePayload(),
    };
    _sendQueueNext = false;
    final client = _ref.read(realtimeClientProvider);
    if (client.isConnected) {
      client.send('broadcast.state', body);
    } else {
      unawaited(_httpPost('/broadcast/state', body));
    }
  }

  /// iOS na pozadí: WS je mrtvý, appka, která hraje, ale smí posílat HTTP.
  Future<void> _httpPost(String path, Map<String, dynamic> body) async {
    final c0 = monoNowMs();
    try {
      final res = await _ref.read(apiClientProvider).postJson(path, body: body, timeout: const Duration(seconds: 15));
      _httpClockSample(c0, res);
      final count = (res['listeners'] as num?)?.toInt();
      if (count != null && state.role == BroadcastRole.broadcasting) state = state.copyWith(listeners: count);
      _listenerPrep = (res['prepMs'] as num?)?.toInt() ?? _listenerPrep;
    } on ApiException catch (e) {
      if (state.role != BroadcastRole.broadcasting) return;
      if (e.statusCode == 409) {
        _sendStart(); // restart API -- celý start znovu
      } else if (e.statusCode == 410 || e.statusCode == 403) {
        _stopBroadcasting(notice: 'Vysílání skončilo.');
      }
    } catch (_) {}
  }

  AudioPlayerState? _prevState;
  double _prevStateAt = 0;

  void _onPlayer(AudioPlayerState? prev, AudioPlayerState next) {
    final prevS = _prevState ?? prev;
    final now = monoNowMs();
    _prevState = next;
    final prevAt = _prevStateAt;
    _prevStateAt = now;
    if (next.nowPlaying == null) return;
    if (_audio.followingBroadcast) return _stopBroadcasting();
    final trackChanged = prevS?.nowPlaying?.recordingId != next.nowPlaying?.recordingId || prevS?.queueIndex != next.queueIndex;
    final playChanged = prevS?.isPlaying != next.isPlaying || prevS?.isBuffering != next.isBuffering;
    final speedChanged = prevS?.speed != next.speed;
    final key = _queueIdentity(next);
    final queueChanged = key != _queueKey;
    _queueKey = key;
    var seek = false;
    if (!trackChanged && prevS != null && next.isPlaying && prevS.isPlaying) {
      final expected = prevS.position.inMilliseconds + (now - prevAt) * next.speed;
      seek = (next.position.inMilliseconds - expected).abs() > 1500;
    } else if (!trackChanged && prevS != null && !next.isPlaying) {
      seek = (next.position - prevS.position).abs() > const Duration(milliseconds: 1500);
    }
    if (trackChanged) {
      _abs++;
      _qv++;
      _plannedFor = null;
      // Plánovaný přechod: nová skladba začíná v čase plánu -- ne "pozastaveno".
      if (_transitionAtServer != null) {
        _startAtServer = _transitionAtServer;
        _startFor = next.nowPlaying!.recordingId;
      }
      _transitionAtServer = null;
      _sendAnchor(discontinuity: true, queue: true);
      return;
    }
    if (queueChanged) {
      _qv++;
      _sendAnchor(discontinuity: false, queue: true);
    }
    if (playChanged || speedChanged || seek) {
      // Rozjezd přesně podle plánu není nespojitost (stejná časová osa).
      final server = clock.serverNow(now);
      final asPlanned = playChanged && next.isPlaying && _startAtServer != null && _startFor == next.nowPlaying!.recordingId && server != null && (server - _startAtServer!).abs() < 1000;
      if (!next.isPlaying || seek || speedChanged) {
        _audio.cancelTransitionPlan();
        _plannedFor = null;
        _transitionAtServer = null;
        if (!asPlanned) _startAtServer = null;
      }
      _sendAnchor(discontinuity: !asPlanned);
    }
  }

  /// Plánovaný start po přeskoku / výběru skladby (volá přehrávač při
  /// načítání): s posluchači oba začnou za Δ, bez posluchačů hned.
  /// Bariéru jde použít: posluchači, platné hodiny, WS (go chodí přes WS),
  /// ne rádio (iPhone v Safari, start nejde odložit).
  bool get _barrierUsable =>
      state.role == BroadcastRole.broadcasting &&
      state.listeners > 0 &&
      clock.isValid &&
      !_audio.radioStreamActive &&
      _ref.read(realtimeClientProvider).isConnected;

  /// Start nové skladby (přeskok, klepnutí ve frontě) -- volá přehrávač při
  /// načítání: s posluchači přes ready bariéru (přehrávač čeká pozastavený
  /// na `go`), bez nich hned.
  double? _planStart() {
    if (!_barrierUsable) return null;
    final s = _ref.read(audioPlayerControllerProvider);
    final np = s.nowPlaying;
    if (np == null) return null;
    _queuePrepare('start', np.recordingId, s.position.inMilliseconds.toDouble());
    return double.infinity;
  }

  /// Play po pauze přes bariéru (krátký limit).
  bool _resumeBarrier() {
    if (!_barrierUsable) return false;
    final s = _ref.read(audioPlayerControllerProvider);
    final np = s.nowPlaying;
    if (np == null || !_audio.sourceReady) return false;
    _queuePrepare('seek', np.recordingId, _audio.exactPosition.inMicroseconds / 1000.0);
    _barrier.ownReady = true; // zdroj je načtený a stojí na pozici
    return true;
  }

  /// Seek za přehrávání přes krátkou bariéru.
  bool _seekBarrier(Duration position) {
    if (!_barrierUsable) return false;
    final np = _ref.read(audioPlayerControllerProvider).nowPlaying;
    if (np == null) return false;
    _queuePrepare('seek', np.recordingId, position.inMicroseconds / 1000.0);
    return true;
  }

  void _ownParked() {
    _barrier.ownReady = true;
    _maybeSendOwnReady();
  }

  /// Rychlé ťukání (další, další...) se slučuje: prepare odejde až po 150 ms
  /// klidu, za poslední volbu; starší bariéra tím na serveru končí.
  void _queuePrepare(String kind, String rid, double positionMs) {
    final ownReady = _pendingPrepare?.rid == rid && _barrier.ownReady;
    _pendingPrepare = (kind: kind, rid: rid, positionMs: positionMs);
    _barrier.ownReady = ownReady;
    _prepareTimer?.cancel();
    _prepareTimer = Timer(const Duration(milliseconds: 150), _sendPrepare);
  }

  void _sendPrepare() {
    final p = _pendingPrepare;
    if (p == null || state.role != BroadcastRole.broadcasting) return;
    final s = _ref.read(audioPlayerControllerProvider);
    if (s.nowPlaying?.recordingId != p.rid) return; // mezitím jinde
    _pendingPrepare = null;
    final ownReady = _barrier.ownReady;
    _barrier.begin(p.rid);
    _barrier.ownReady = ownReady;
    _epoch++;
    final server = clock.serverNow(monoNowMs()) ?? 0;
    final anchor = BroadcastAnchor(
      recordingId: p.rid,
      index: _abs,
      qv: _qv,
      epoch: _epoch,
      positionMs: p.positionMs,
      atServerMs: server,
      rate: s.speed,
      isPlaying: true,
      durationMs: s.duration?.inMilliseconds.toDouble(),
      repeatMode: s.repeatMode == RepeatMode.one ? 'one' : 'off',
    );
    _ref.read(realtimeClientProvider).send('broadcast.prepare', {
      'sid': state.sid,
      'bid': _bid,
      'bseq': ++_bseq,
      'kind': p.kind,
      'anchor': anchor.toJson(),
      if (_sendQueueNext) 'queue': _queuePayload(),
    });
    _sendQueueNext = false;
    _diagEvent('PREPARE B kind=${p.kind} rid=${p.rid} pos=${_f(p.positionMs)} ${_clockDiag()}');
  }

  void _maybeSendOwnReady() {
    if (!_barrier.readyToReport) return;
    final local = _audio.currentSourceLocal;
    _ref.read(realtimeClientProvider).send('broadcast.ready', {
      'sid': state.sid,
      'epoch': _barrier.epoch,
      'rtt': clock.minRtt.isFinite ? clock.minRtt : null,
      'startLeadMs': _latency.p80(local),
    });
    // Pojistka: server neodpoví (výpadek) -> po 6 s hrát hned.
    final epoch = _barrier.epoch;
    _goFallback?.cancel();
    _goFallback = Timer(const Duration(seconds: 6), () {
      if (_barrier.epoch != epoch || !_barrier.active) return;
      _barrier.clear();
      _diagEvent('GO-FALLBACK B epoch=$epoch');
      _audio.playAt(monoNowMs());
      _sendAnchor(discontinuity: true);
    });
  }

  void _onOwnerGo(Map<String, dynamic> p) {
    final epoch = (p['epoch'] as num?)?.toInt();
    final t = (p['atServerMs'] as num?)?.toDouble();
    final offset = clock.offsetMs;
    if (epoch == null || t == null || offset == null || !_barrier.acceptsGo(epoch)) return;
    _goFallback?.cancel();
    final rid = _barrier.recordingId;
    _barrier.clear();
    _startAtServer = t;
    _startFor = rid;
    final audio = _audio;
    final local = audio.currentSourceLocal;
    audio.startLeadMs = _latency.estimate(local);
    audio.playAt(t - offset);
    _expectStart('barrier', t, local: local);
  }

  /// Vysílač: ~20 s před koncem naplánovat přirozený přechod (K4) --
  /// jen s posluchači, platnými hodinami a mimo rádio.
  void _broadcasterTick() {
    if (state.role != BroadcastRole.broadcasting) return;
    _diagBroadcaster();
    final now = monoNowMs();
    // Na pozadí bez WS: heartbeat přes HTTP každých 30 s.
    final client = _ref.read(realtimeClientProvider);
    if (!client.isConnected && now - _lastHttpBeat > 30000) {
      _lastHttpBeat = now;
      _sendAnchor(discontinuity: false);
    }
    if (state.listeners == 0 || !clock.isValid) return;
    final s = _ref.read(audioPlayerControllerProvider);
    final np = s.nowPlaying;
    final dur = s.duration;
    if (np == null || dur == null || !s.isPlaying || _audio.radioStreamActive || s.repeatMode == RepeatMode.one) return;
    if (s.nextIndex == null || !_audio.sourceReady) return;
    final key = '${np.recordingId}|$_abs';
    if (_plannedFor == key) return;
    final pos = _audio.exactPosition.inMicroseconds / 1000.0;
    final remaining = dur.inMilliseconds - pos;
    if (remaining > 20000 || remaining < 1500) return;
    final server = clock.serverNow(now)!;
    final xServer = plannedTransitionAt(atServerMs: server, positionMs: pos, durationMs: dur.inMilliseconds.toDouble(), rate: s.speed);
    final xMono = xServer - clock.offsetMs!;
    _audio.startLeadMs = _latency.estimate(_audio.currentSourceLocal);
    _audio.planTransition(xMono: xMono, loadAtMono: loadAt(x: xMono, loadLeadMs: _loadLead.valueMs, startLeadMs: _audio.startLeadMs));
    _expectStart('transition', xServer, local: _audio.currentSourceLocal);
    _plannedFor = key;
    _transitionAtServer = xServer;
    _sendAnchor(discontinuity: false);
  }

  // --- posluchač ---------------------------------------------------------

  final TimelineModel _model = TimelineModel();
  final SyncRegulator _regulator = SyncRegulator();
  Map<String, dynamic>? _snapshot;
  List<NowPlayingInfo> _queue = const [];
  int _queueBase = 0;
  int _queueQv = -1;
  int? _loadedAbs;
  String? _lastClockId;
  int _lastGen = -1;
  int _lastSeq = -1;
  double _lastSyncAsk = -1e9;
  double? _transitionStartedFor;
  double? _pendingSince;
  bool _localPaused = false;
  double _commandedAt = -1e9;
  double _lastTickWall = 0;
  double _lastTickMono = 0;
  Timer? _endTimer;
  bool _pollActive = false;
  final LeadEstimate _listenerLoad = LeadEstimate(150);
  int? _sentPrep;

  /// Přehrávač má frontu vysílače (okno), ne jen skladbu z karty / staré okno.
  bool _playerQueueOurs = false;
  ProviderSubscription<AudioPlayerState>? _listenerPlayerSub;

  int _prepMs() => (_listenerLoad.valueMs + _latency.p80(_audio.currentSourceLocal) + 100).round();

  /// "Připojit": odloží vlastní frontu a hraje to, co vysílač. Volat přímo
  /// z klepnutí -- web smí spustit zvuk jen v reakci na gesto (proto se
  /// skladba vysílače z karty načte hned, pozastaveně).
  void join(LiveBroadcast b) {
    if (b.mine) return;
    if (state.role == BroadcastRole.broadcasting) _stopBroadcasting();
    final audio = _audio;
    if (state.role == BroadcastRole.listening) {
      _ref.read(realtimeClientProvider).send('broadcast.leave', {'sid': state.sid});
    } else {
      _snapshot = audio.handoffSnapshot();
    }
    _model.anchor = null;
    _queue = const [];
    _queueQv = -1;
    _loadedAbs = null;
    _lastClockId = null;
    _lastGen = -1;
    _lastSeq = -1;
    _transitionStartedFor = null;
    _pendingSince = null;
    _localPaused = false;
    _barrierEpoch = null;
    _solo = null;
    _lastSolo = -1e9;
    _parkTarget = null;
    _startMono = null;
    _playerQueueOurs = false;
    _endTimer?.cancel();
    _regulator.reset(monoNowMs());
    state = state.copyWith(role: BroadcastRole.listening, sid: b.id, hostName: b.name, waiting: true, clearEnded: true, clearNotice: true, weakSync: false);
    audio.onSourceLoaded = (ms, cached) {
      _listenerLoad.add(ms);
      final prep = _prepMs();
      if (_sentPrep == null || (prep - _sentPrep!).abs() > 100) {
        _sentPrep = prep;
        _ref.read(realtimeClientProvider).send('broadcast.prep', {'prepMs': prep, 'healthy': !_regulator.looseMode});
      }
    };
    // Skladba z karty hned (gesto pro web), pozastaveně -- přesné místo dodá kotva.
    if (b.recordingId != null && b.title != null) {
      unawaited(audio.followStart(
        [NowPlayingInfo(recordingId: b.recordingId!, title: b.title!, artistName: b.artist, artworkUrl: b.artworkUrl)],
        0,
        position: Duration.zero,
        playAtMono: double.infinity,
        label: _label,
      ));
    }
    audio.onPlayBlocked = _onPlayBlocked;
    audio.onOwnPlaybackWhileFollowing = _leftByOwnPlayback;
    _listenerPlayerSub?.close();
    _listenerPlayerSub = _ref.listen<AudioPlayerState>(audioPlayerControllerProvider, _onListenerPlayer);
    _startClock();
    _ref.read(realtimeClientProvider).send('broadcast.join', {'sid': b.id, 'prepMs': _prepMs()});
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _listenerTick());
  }

  String get _label => 'Stream · ${state.hostName ?? ''}';

  /// Posluchač pustil vlastní hudbu -- odchod bez obnovy fronty (vybral si
  /// něco jiného).
  void _leftByOwnPlayback() {
    if (state.role != BroadcastRole.listening) return;
    _diagFlush();
    _ref.read(realtimeClientProvider).send('broadcast.leave', {'sid': state.sid});
    _tick?.cancel();
    _clockTimer?.cancel();
    _endTimer?.cancel();
    _pollActive = false;
    _listenerPlayerSub?.close();
    _listenerPlayerSub = null;
    final audio = _audio;
    audio.onSourceLoaded = null;
    audio.onPlayBlocked = null;
    audio.onStartMeasured = null;
    audio.onOwnPlaybackWhileFollowing = null;
    _snapshot = null;
    state = BroadcastState(live: state.live);
  }

  /// "Odejít" / "Vrátit se k mému": zpátky vlastní fronta a místo (pozastaveně).
  Future<void> leave() async {
    if (state.role != BroadcastRole.listening) return;
    _diagFlush();
    final sid = state.sid;
    _ref.read(realtimeClientProvider).send('broadcast.leave', {'sid': sid});
    _tick?.cancel();
    _clockTimer?.cancel();
    _endTimer?.cancel();
    _pollActive = false;
    _listenerPlayerSub?.close();
    _listenerPlayerSub = null;
    _audio.onSourceLoaded = null;
    _audio.onPlayBlocked = null;
    _audio.onStartMeasured = null;
    _audio.onOwnPlaybackWhileFollowing = null;
    final snapshot = _snapshot;
    _snapshot = null;
    state = BroadcastState(live: state.live);
    await _audio.endFollow(restore: snapshot);
  }

  void _onListenerPlayer(AudioPlayerState? prev, AudioPlayerState next) {
    // Pauza / play od uživatele (ne náš povel) -> lokální pauza / znovu srovnat.
    if (prev?.isPlaying == next.isPlaying || monoNowMs() - _commandedAt < 1500) return;
    if (!next.isPlaying && !next.isBuffering) {
      _localPaused = true;
    } else if (next.isPlaying && _localPaused) {
      _localPaused = false;
      _regulator.reset(monoNowMs());
    }
  }

  void _onListenerState(Map<String, dynamic> p) {
    // Pořadí (clockId, gen, seq) od serveru; jiné clockId (restart API) nebo
    // odpověď na join/sync = srovnání od nuly (N1).
    final gen = (p['gen'] as num?)?.toInt() ?? 0;
    final reset = p['reset'] == true || p['clockId'] != _lastClockId;
    if (gen != _lastGen && !reset && p['queue'] == null) {
      _askSync();
      return;
    }
    final seq = (p['seq'] as num?)?.toInt() ?? 0;
    if (!reset && gen == _lastGen && seq <= _lastSeq) return;
    if (!_acceptOrder(p)) return;
    final name = p['name'] as String?;
    if (name != null && name != state.hostName) state = state.copyWith(hostName: name);
    _takeQueue(p);
    final a = p['anchor'] as Map<String, dynamic>?;
    if (a == null) return;
    final anchor = BroadcastAnchor.fromJson(a);
    if (anchor.qv != _queueQv) {
      // Kotva k frontě, kterou nemáme -- nikdy nehrát podle nesouladné fronty.
      _askSync();
      return;
    }
    // Běžný stav během bariéry (vysílač mezitím pauzl) bariéru ruší.
    if (_barrierEpoch != null) _barrierEpoch = null;
    if (_model.apply(anchor)) {
      _regulator.reset(monoNowMs());
    }
    if (state.waiting) state = state.copyWith(waiting: false);
    _listenerTick();
  }

  void _askSync() {
    final now = monoNowMs();
    if (now - _lastSyncAsk < 1000) return;
    _lastSyncAsk = now;
    _ref.read(realtimeClientProvider).send('broadcast.sync', {'sid': state.sid});
  }

  /// Přehrávač má stejnou frontu jako vysílač (okno), bez přerušení skladby.
  void _syncPlayerQueue() {
    if (_queue.isEmpty) return;
    final s = _ref.read(audioPlayerControllerProvider);
    final loaded = _loadedAbs;
    final li = loaded == null ? -1 : loaded - _queueBase;
    if (li >= 0 && li < _queue.length && s.nowPlaying?.recordingId == _queue[li].recordingId) {
      _audio.followReplaceQueue(_queue, li, _label);
      _playerQueueOurs = true;
    } else {
      _playerQueueOurs = false; // další načtení vezme celou novou frontu
    }
  }

  /// Načíst položku `li` fronty vysílače: v převzaté frontě skokem, jinak
  /// celou frontu znovu.
  Future<void> _load(int li, {required double positionMs, double? playAtMono}) {
    final position = Duration(milliseconds: positionMs.round());
    if (_playerQueueOurs && _audio.followingBroadcast) {
      return _audio.followJump(li, position: position, playAtMono: playAtMono);
    }
    _playerQueueOurs = true;
    return _audio.followStart(_queue, li, position: position, playAtMono: playAtMono, label: _label);
  }

  double? _durationOf(int abs) {
    final i = abs - _queueBase;
    if (i < 0 || i >= _queue.length) return null;
    return _queue[i].durationMs?.toDouble();
  }

  void _onEnded(String reason) {
    state = state.copyWith(ended: reason, waiting: false);
    _tick?.cancel();
    _clockTimer?.cancel();
    _pollActive = false;
    // Dohrát aktuální skladbu, pak pozastavit a nabídnout návrat (rozhodnutí 2).
    final audio = _audio;
    final s = _ref.read(audioPlayerControllerProvider);
    final dur = s.duration;
    if (!audio.playerPlaying || dur == null) return;
    final left = dur - audio.exactPosition - const Duration(milliseconds: 400);
    _endTimer?.cancel();
    _endTimer = Timer(left.isNegative ? Duration.zero : left, () => unawaited(audio.followPause()));
  }

  Future<void> _command(Future<void> Function() f) {
    _commandedAt = monoNowMs();
    return f().catchError((Object _) {});
  }

  // --- diagnostika (client-log, jen během vysílání / poslechu) ------------
  //
  // 1 záznam za ~2 s, odeslání dávkou po ~20 s jako `broadcast-sync` do
  // /data/db/client-log.jsonl -- ať reálný test dá data (16. 10.).

  final List<String> _diagLines = [];
  double _diagLast = -1e9;
  double _diagSent = -1e9;
  String? _diagAction;

  String _f(double? v) => v == null ? '-' : v.round().toString();

  void _diag(String line) {
    final now = monoNowMs();
    if (now - _diagLast < 2000) return;
    _diagLast = now;
    _diagLines.add(line);
    if (_diagLines.length >= 10 || now - _diagSent > 20000) _diagFlush();
  }

  /// Mimořádná událost (start, bariéra, připravený start, zablokovaný zvuk) --
  /// vždy, bez omezení na 1 za 2 s.
  void _diagEvent(String line) {
    _diagLines.add(line);
    if (_diagLines.length >= 10 || monoNowMs() - _diagSent > 20000) _diagFlush();
  }

  void _diagFlush() {
    if (_diagLines.isEmpty) return;
    _diagSent = monoNowMs();
    final detail = _diagLines.join('\n');
    _diagLines.clear();
    unawaited(_ref
        .read(apiClientProvider)
        .postJson('/client-log', body: {'kind': 'broadcast-sync', 'detail': detail, 'platform': defaultTargetPlatform.name})
        .then((_) {}, onError: (Object _) {}));
  }

  String _clockDiag() => 'off=${_f(clock.isValid ? clock.offsetMs : null)} rtt=${_f(clock.minRtt.isFinite ? clock.minRtt : null)} ok=${clock.isValid ? 1 : 0}';

  void _diagListener(BroadcastAnchor? a, SyncTarget? t, double? serverNow, double? pos) {
    final audio = _audio;
    final action = _diagAction ?? '-';
    _diagAction = null;
    _diag('L ${_clockDiag()} '
        'age=${_f(a == null || serverNow == null ? null : serverNow - a.atServerMs)} '
        'aP=${_f(a?.positionMs)} aT=${_f(a?.atServerMs)} aPlay=${a?.isPlaying == true ? 1 : 0} aOk=${a?.clockOk == false ? 0 : 1} '
        'start=${_f(a?.startAtServerMs)} trans=${_f(a?.transitionAtServerMs)} '
        'tI=${t?.index ?? '-'} tP=${_f(t?.positionMs)} tW=${t?.waitingForStart == true ? 1 : 0} loaded=${_loadedAbs ?? '-'} '
        'pos=${_f(pos)} err=${_f(pos == null || t == null ? null : pos - t.positionMs)} ef=${_f(_regulator.filteredErrorMs)} '
        'act=$action step=${_regulator.step} solo=${_solo ?? '-'} bar=${_barrierEpoch ?? '-'} parkLead=${_f(_parkLead)} '
        'evPos=${audio.lastPlaybackEvent.updatePosition.inMilliseconds} evAge=${DateTime.now().difference(audio.lastPlaybackEvent.updateTime).inMilliseconds} '
        'loose=${_regulator.looseMode ? 1 : 0} ready=${audio.sourceReady ? 1 : 0} play=${audio.playerPlaying ? 1 : 0} '
        'local=${audio.currentSourceLocal ? 1 : 0} est=${_f(_latency.estimate(audio.currentSourceLocal))} lp=${_localPaused ? 1 : 0}');
  }

  void _diagBroadcaster() {
    final s = _ref.read(audioPlayerControllerProvider);
    final audio = _audio;
    _diag('B ${_clockDiag()} bar=${_barrier.epoch ?? (_barrier.active ? '?' : '-')} pos=${_f(audio.exactPosition.inMicroseconds / 1000.0)} uiPos=${s.position.inMilliseconds} '
        'dur=${s.duration?.inMilliseconds ?? '-'} play=${audio.playerPlaying ? 1 : 0} st=${s.isPlaying ? 1 : 0} buf=${s.isBuffering ? 1 : 0} '
        'ready=${audio.sourceReady ? 1 : 0} radio=${audio.radioStreamActive ? 1 : 0} abs=$_abs ep=$_epoch qv=$_qv '
        'lis=${state.listeners} plan=${_f(_transitionAtServer)} startAt=${_f(_startAtServer)} ws=${_ref.read(realtimeClientProvider).isConnected ? 1 : 0}');
  }

  // --- posluchač: bariéra a připravený start ------------------------------
  //
  // Žádný seek za běhu dokola (Kryštof 16. 10.: "přeskakovalo, nehrálo,
  // hrálo"). Start skupiny = bariéra (prepare -> zaparkovat -> ready -> go v
  // T). Dohánění jednoho (připojení, lagging, po bufferingu / pozadí, velká
  // odchylka) = připravený start pro jednoho: ztichnout, zaparkovat na cíli
  // za chvíli, ready -> vlastní go v T -> začít naráz. Za běhu jen rychlost.

  int? _barrierEpoch;
  bool _readySent = false;

  /// Kam je přehrávač zaparkovaný (absolutní index, pozice).
  ({int abs, double pos})? _parkTarget;
  bool _parkSeeking = false;

  /// Připravený start pro jednoho: null | 'parking' | 'awaiting'.
  String? _solo;
  double _soloSince = -1e9;
  double _lastSolo = -1e9;
  double _parkLead = 3500;
  String _soloReason = '';

  /// Naplánovaný start (mono) -- do té doby a chvíli po něm neřídit.
  double? _startMono;
  bool _suspendSent = false;

  void _park(int abs, double pos) {
    final li = abs - _queueBase;
    if (li < 0 || li >= _queue.length) return _askSync();
    _parkTarget = (abs: abs, pos: pos);
    final audio = _audio;
    if (_loadedAbs != abs || !audio.followingBroadcast) {
      _loadedAbs = abs;
      unawaited(_command(() => _load(li, positionMs: pos, playAtMono: double.infinity)));
      return;
    }
    _parkSeeking = true;
    unawaited(_command(() async {
      await audio.followPause();
      await audio.followSeek(Duration(milliseconds: pos.round()));
    }).whenComplete(() => _parkSeeking = false));
  }

  bool _parkedReady() {
    final p = _parkTarget;
    final audio = _audio;
    if (p == null || _parkSeeking || _loadedAbs != p.abs || !audio.sourceReady || audio.playerPlaying) return false;
    return (audio.exactPosition.inMicroseconds / 1000.0 - p.pos).abs() < 150;
  }

  void _onPrepare(Map<String, dynamic> p) {
    if (!_acceptOrder(p)) return;
    _takeQueue(p);
    final a = p['anchor'] as Map<String, dynamic>?;
    if (a == null) return;
    final anchor = BroadcastAnchor.fromJson({...a, 'isPlaying': false});
    _model.anchor = anchor; // do `go` stojí na pozici
    _barrierEpoch = (p['epoch'] as num?)?.toInt();
    _readySent = false;
    _solo = null;
    _startMono = null;
    _regulator.reset(monoNowMs());
    if (state.waiting) state = state.copyWith(waiting: false);
    _diagEvent('PREPARE L epoch=$_barrierEpoch rid=${anchor.recordingId} pos=${_f(anchor.positionMs)}');
    _park(anchor.index, anchor.positionMs);
  }

  void _onGroupGo(Map<String, dynamic> p) {
    final epoch = (p['epoch'] as num?)?.toInt();
    final a = p['anchor'] as Map<String, dynamic>?;
    if (a == null) return;
    _acceptOrder(p, force: true);
    final anchor = BroadcastAnchor.fromJson(a);
    _model.anchor = anchor;
    final wasOurs = epoch != null && epoch == _barrierEpoch;
    _barrierEpoch = null;
    final offset = clock.offsetMs;
    if (wasOurs && offset != null && _parkedReady() && _parkTarget!.abs == anchor.index) {
      _startAt(anchor.startAtServerMs ?? anchor.atServerMs, anchor.positionMs, 'barrier');
    } else {
      // Nestihl limit (lagging): dožene se připraveným startem sám.
      _diagEvent('LAGGING L epoch=$epoch parked=${_parkedReady() ? 1 : 0}');
      _lastSolo = -1e9;
      _beginSolo('lagging');
    }
  }

  void _onSoloGo(Map<String, dynamic> p) {
    if (_solo != 'awaiting') return;
    final t = (p['atServerMs'] as num?)?.toDouble();
    final pos = (p['positionMs'] as num?)?.toDouble();
    if (t == null || pos == null) return;
    _applySoloGo(t, pos, p['isPlaying'] != false);
  }

  void _applySoloGo(double t, double pos, bool playing) {
    _solo = null;
    final park = _parkTarget;
    if (!playing) {
      if (park != null) _park(park.abs, pos);
      return;
    }
    // Server zvolil pozdější místo, než kam jsme zaparkovali -> příště dál.
    if (park != null) {
      final behind = pos - park.pos;
      _parkLead = behind > 30 ? math.min(8000, _parkLead + behind + 500) : math.max(2500, _parkLead - 200);
    }
    _startAt(t, pos, 'solo:$_soloReason');
  }

  /// Rozehrát zaparkovaný přehrávač tak, aby zazněl v serverovém čase `t`
  /// na pozici `pos` (play() v T − naučená latence).
  void _startAt(double t, double pos, String kind) {
    final offset = clock.offsetMs;
    if (offset == null) return;
    final audio = _audio;
    final local = audio.currentSourceLocal;
    final tMono = t - offset;
    _startMono = tMono;
    _suspendSent = false;
    _regulator.reset(monoNowMs());
    _regulator.settle(tMono);
    audio.startLeadMs = _latency.estimate(local);
    final needSeek = (audio.exactPosition.inMicroseconds / 1000.0 - pos).abs() > 30;
    unawaited(_command(() async {
      if (needSeek) await audio.followSeek(Duration(milliseconds: pos.round()));
      audio.playAt(tMono);
    }));
    _expectStart(kind, t, local: local);
  }

  /// Připravený start pro jednoho. Nejvýš jednou za 3 s.
  void _beginSolo(String reason) {
    final now = monoNowMs();
    if (now - _lastSolo < 3000 || _barrierEpoch != null) return;
    final a = _model.anchor;
    final serverNow = clock.serverNow(now);
    if (a == null || serverNow == null || _queue.isEmpty) return;
    _lastSolo = now;
    if (!a.isPlaying) {
      _park(a.index, a.positionMs);
      return;
    }
    final t = targetAt(a, serverNow + _parkLead, durationOf: _durationOf, queueEnd: _queueBase + _queue.length);
    if (t.ended) return;
    _solo = 'parking';
    _soloSince = now;
    _soloReason = reason;
    _startMono = null;
    _diagEvent('SOLO L reason=$reason park=${_f(t.positionMs)} lead=${_f(_parkLead)} tI=${t.index}');
    _park(t.index, t.positionMs);
  }

  void _sendSoloReady() {
    final p = _parkTarget!;
    final local = _audio.currentSourceLocal;
    final client = _ref.read(realtimeClientProvider);
    final item = _queue[p.abs - _queueBase];
    if (client.isConnected) {
      client.send('broadcast.ready', {
        'sid': state.sid,
        'solo': true,
        'recordingId': item.recordingId,
        'index': p.abs,
        'positionMs': p.pos,
        'rtt': clock.minRtt.isFinite ? clock.minRtt : null,
        'startLeadMs': _latency.p80(local),
      });
      _solo = 'awaiting';
      _soloSince = monoNowMs();
      return;
    }
    // Bez WS (pozadí): stejný výpočet jako server, z vlastních hodin.
    final a = _model.anchor;
    final serverNow = clock.serverNow(monoNowMs());
    if (a == null || serverNow == null) return;
    _solo = 'awaiting';
    final (t, pos) = soloGo(a, serverNow: serverNow, parkedMs: p.pos, rttMs: clock.minRtt.isFinite ? clock.minRtt : 100, startLeadMs: _latency.p80(local));
    _applySoloGo(t, pos, true);
  }

  Completer<String?>? _addWaiting;

  /// Posluchač: "Přidat do fronty streamu". Vrací `null` = přidáno, jinak důvod.
  Future<String?> addToStream(NowPlayingInfo info) async {
    if (state.role != BroadcastRole.listening || state.ended != null) return 'Teď neposloucháš žádné vysílání.';
    final client = _ref.read(realtimeClientProvider);
    if (!client.isConnected) return 'Bez spojení se serverem.';
    final c = Completer<String?>();
    _addWaiting = c;
    client.send('broadcast.add', {
      'sid': state.sid,
      'item': {
        ...AudioPlayerController.queueItemToJson(info),
        'recordingId': info.recordingId,
        'title': info.title,
        if (info.artistName != null) 'artistName': info.artistName,
        if (info.artworkUrl != null) 'artworkUrl': withoutDeviceToken(info.artworkUrl!),
      },
    });
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () => 'Server neodpověděl.');
  }

  /// "Klepni pro zvuk" (Safari bez gesta): play v gestu odemkne zvuk, pak
  /// připravený start na správné místo.
  void tapForSound() {
    if (state.role != BroadcastRole.listening) return;
    state = state.copyWith(needsTap: false);
    _audio.playFromGesture();
    _lastSolo = -1e9;
    Timer(const Duration(milliseconds: 300), () => _beginSolo('tap'));
  }

  void _onPlayBlocked(Object error) {
    _diagEvent('PLAY-BLOCKED ${state.role == BroadcastRole.broadcasting ? 'B' : 'L'} $error');
    if (state.role == BroadcastRole.listening && error.toString().contains('NotAllowed')) {
      state = state.copyWith(needsTap: true);
    }
  }

  bool _acceptOrder(Map<String, dynamic> p, {bool force = false}) {
    final clockId = p['clockId'] as String?;
    final gen = (p['gen'] as num?)?.toInt() ?? 0;
    final seq = (p['seq'] as num?)?.toInt() ?? 0;
    final reset = force || p['reset'] == true || clockId != _lastClockId;
    if (!reset && (gen < _lastGen || (gen == _lastGen && seq < _lastSeq))) return false;
    _lastClockId = clockId;
    _lastGen = gen;
    _lastSeq = seq;
    _pendingSince = null;
    return true;
  }

  void _takeQueue(Map<String, dynamic> p) {
    final q = p['queue'] as Map<String, dynamic>?;
    if (q == null) return;
    _queue = [
      for (final i in (q['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
        if (i['id'] is String && i['t'] is String) AudioPlayerController.queueItemFromJson(i),
    ];
    _queueBase = (q['baseIndex'] as num?)?.toInt() ?? 0;
    _queueQv = (q['qv'] as num?)?.toInt() ?? 0;
    _syncPlayerQueue();
  }

  void _listenerTick() {
    if (state.role != BroadcastRole.listening || state.ended != null) return;
    final now = monoNowMs();
    final wall = DateTime.now().millisecondsSinceEpoch.toDouble();
    final usable = positionSampleUsable(wallDeltaMs: wall - _lastTickWall, monoDeltaMs: now - _lastTickMono);
    _lastTickWall = wall;
    _lastTickMono = now;
    final client = _ref.read(realtimeClientProvider);
    if (!client.isConnected && !_pollActive) unawaited(_pollLoop());
    final pending = _pendingSince;
    if (pending != null && now - pending > 60000) return _onEnded('unknown');
    final a = _model.anchor;
    final serverNow = clock.serverNow(now);
    final audio = _audio;
    // Hodiny neplatné: neřídit, jen hrát dál (S4).
    if (a == null || serverNow == null || _queue.isEmpty) {
      _diagListener(a, null, serverNow, null);
      return;
    }

    // Bariéra skupiny: zaparkovat a nahlásit ready, nic dalšího.
    if (_barrierEpoch != null) {
      if (!_readySent && _parkedReady()) {
        _readySent = true;
        client.send('broadcast.ready', {
          'sid': state.sid,
          'epoch': _barrierEpoch,
          'rtt': clock.minRtt.isFinite ? clock.minRtt : null,
          'startLeadMs': _latency.p80(audio.currentSourceLocal),
        });
      }
      _diagListener(a, null, serverNow, null);
      return;
    }
    // Připravený start pro jednoho.
    if (_solo == 'parking') {
      if (_parkedReady()) {
        _sendSoloReady();
      } else if (now - _soloSince > 10000) {
        // Nenačetlo se ani za 10 s (hlídač startu mezitím zkouší znovu načíst).
        _parkLead = math.min(8000, _parkLead + 2000);
        _lastSolo = -1e9;
        _beginSolo('slow-park');
      }
      _diagListener(a, null, serverNow, null);
      return;
    }
    if (_solo == 'awaiting') {
      if (now - _soloSince > 3000) {
        _solo = null; // go nepřišlo -- znovu
        _beginSolo('no-go');
      }
      return;
    }
    // Naplánovaný start ještě nenastal -- čekat.
    final startMono = _startMono;
    if (startMono != null && now < startMono + 300) return;

    final t = targetAt(a.clockOk ? a : a.copyWith(clearTransition: true), serverNow, durationOf: _durationOf, queueEnd: _queueBase + _queue.length);
    final li = t.index - _queueBase;
    if (li < 0 || li >= _queue.length) return _askSync();
    if (t.ended) {
      if (audio.playerPlaying) unawaited(_command(audio.followPause));
      return;
    }
    final offset = clock.offsetMs!;
    final s = _ref.read(audioPlayerControllerProvider);

    // Načtená skladba z karty: když sedí na frontu, jen převzít frontu.
    if (_loadedAbs == null && audio.followingBroadcast && s.nowPlaying?.recordingId == _queue[li].recordingId && s.queue.length <= 1) {
      _loadedAbs = t.index;
      audio.followReplaceQueue(_queue, li, _label);
      _playerQueueOurs = true;
    }

    // Plánovaný přirozený přechod: další skladbu načíst o chvilku dřív a
    // rozehrát přesně v čase plánu (N3).
    final x = a.clockOk ? a.transitionAtServerMs : null;
    if (x != null && _loadedAbs == a.index && t.index == a.index && _transitionStartedFor != x && li + 1 < _queue.length && !_localPaused && audio.playerPlaying) {
      final xMono = x - offset;
      final local = audio.currentSourceLocal;
      audio.startLeadMs = _latency.estimate(local);
      if (now >= loadAt(x: xMono, loadLeadMs: _listenerLoad.valueMs, startLeadMs: audio.startLeadMs)) {
        _transitionStartedFor = x;
        _loadedAbs = a.index + 1;
        _startMono = xMono;
        _regulator.reset(now);
        _regulator.settle(xMono);
        unawaited(_command(() => _load(li + 1, positionMs: 0, playAtMono: xMono)));
        _expectStart('transition', x, local: local);
        return;
      }
    }

    if (t.index != _loadedAbs) {
      // Jiná skladba bez bariéry (připojení, výpadek, vysílač bez posluchačů
      // přeskočil): hraje -> připravený start, stojí -> zaparkovat.
      if (t.playing && !_localPaused) {
        _beginSolo('track');
      } else {
        _park(t.index, t.positionMs);
      }
      return;
    }

    if (!audio.sourceReady) {
      // Buffering za hraní: skupinu nezastavuje (suspended), po něm dohnat.
      if (t.playing && !_suspendSent && s.isBuffering) {
        _suspendSent = true;
        client.send('broadcast.suspend', {'sid': state.sid, 'reason': 'buffering'});
      }
      _diagListener(a, t, serverNow, null);
      return;
    }
    final pos = audio.exactPosition.inMicroseconds / 1000.0;
    audio.followBaseSpeed(a.rate);

    if (!t.playing) {
      // Vysílač stojí: stát na přesném místě (play pak přijde bariérou).
      if (audio.playerPlaying) unawaited(_command(audio.followPause));
      if ((pos - t.positionMs).abs() > 40 && !_parkSeeking) {
        _parkSeeking = true;
        unawaited(_command(() => audio.followSeek(Duration(milliseconds: t.positionMs.round()))).whenComplete(() => _parkSeeking = false));
      }
      return;
    }
    if (_localPaused) return;
    if (!audio.playerPlaying || _suspendSent) {
      // Vysílač hraje, my stojíme (po bufferingu, po pauze bez bariéry):
      // připravený start, ne seek a play.
      _suspendSent = false;
      _beginSolo(audio.playerPlaying ? 'buffering' : 'resume');
      return;
    }
    if (!usable) return;
    final action = _regulator.observe(nowMs: now, errorMs: pos - t.positionMs, baseRate: a.rate);
    if (action.kind != SyncActionKind.none) _diagAction = action.toString();
    _diagListener(a, t, serverNow, pos);
    switch (action.kind) {
      case SyncActionKind.none:
        break;
      case SyncActionKind.setRate:
        unawaited(audio.followSetRate(action.rate!).catchError((Object _) => _regulator.rateUnsupported()));
      case SyncActionKind.resync:
        _lastSolo = -1e9;
        _beginSolo('drift');
    }
    if (_regulator.looseMode != state.weakSync) {
      state = state.copyWith(weakSync: _regulator.looseMode);
      client.send('broadcast.prep', {'prepMs': _prepMs(), 'healthy': !_regulator.looseMode});
    }
  }

  /// Posluchač bez WS (iOS na pozadí): stav long-pollem přes HTTP (K5).
  Future<void> _pollLoop() async {
    if (_pollActive) return;
    _pollActive = true;
    final api = _ref.read(apiClientProvider);
    final client = _ref.read(realtimeClientProvider);
    try {
      while (_pollActive && state.role == BroadcastRole.listening && state.ended == null && !client.isConnected) {
        final sid = state.sid;
        final after = _lastClockId == null ? null : '$_lastClockId.$_lastGen.$_lastSeq';
        final c0 = monoNowMs();
        try {
          final body = await api.getJsonMaybe('/broadcast/$sid/state', query: {
            if (after != null) 'after': after,
            'wait': '25',
          }, timeout: const Duration(seconds: 35));
          if (body == null) continue;
          _httpClockSample(c0, body);
          if (body['ended'] != null) {
            _onEnded(body['ended'] as String);
            break;
          }
          if (body['pending'] == true) {
            _pendingSince ??= monoNowMs();
            await Future<void>.delayed(const Duration(seconds: 3));
            continue;
          }
          _onListenerState(body);
        } on ApiException catch (e) {
          if (e.statusCode == 404) {
            _onEnded('unknown');
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 3));
        } catch (_) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
    } finally {
      _pollActive = false;
    }
  }

  void clearNotice() {
    if (state.notice != null) state = state.copyWith(clearNotice: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events.close();
    // Přepnutí profilu / odhlášení uprostřed vysílání nebo poslechu: vysílání
    // ukončit (jinak by do 90 s viselo v seznamu) a přehrávači vrátit
    // normální režim (poslechy, fronta...). Cizí fronta se novému profilu
    // neobnovuje -- jen se zastaví.
    try {
      if (state.role == BroadcastRole.broadcasting) {
        _client.send('broadcast.stop', {'sid': state.sid, 'bid': _bid});
      } else if (state.role == BroadcastRole.listening) {
        _client.send('broadcast.leave', {'sid': state.sid});
      }
    } catch (_) {}
    try {
      final audio = _audioRef;
      if (audio.mounted && audio.followingBroadcast) unawaited(audio.endFollow().catchError((Object _) {}));
      if (audio.mounted) {
        if (audio.broadcastStartPlanner == _planStart) audio.broadcastStartPlanner = null;
        audio.broadcastResumeBarrier = null;
        audio.broadcastSeekBarrier = null;
        audio.onBarrierParked = null;
        audio.onPlayBlocked = null;
        audio.onStartMeasured = null;
        audio.onSourceLoaded = null;
        audio.cancelTransitionPlan();
      }
    } catch (_) {}
    _playerSub?.close();
    _heartbeat?.cancel();
    _tick?.cancel();
    _clockTimer?.cancel();
    _sendTimer?.cancel();
    _prepareTimer?.cancel();
    _goFallback?.cancel();
    _startCheckTimer?.cancel();
    _pollActive = false;
    _listenerPlayerSub?.close();
    _endTimer?.cancel();
    super.dispose();
  }
}
