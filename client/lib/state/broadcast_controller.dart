import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart' show ApiException;
import '../core/broadcast_sync.dart';
import '../core/config.dart';
import '../core/device_token.dart' show withDeviceToken, withoutDeviceToken;
import '../core/realtime_event.dart';
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
  });

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
    client.addConnectListener(_onConnected);
    _events = _ref.listen<AsyncValue<RealtimeEvent>>(realtimeEventsProvider, (_, next) {
      final event = next.valueOrNull;
      if (event is ConnectEvent) _onEvent(event);
    });
    if (client.isConnected) client.send('broadcasts.list', {});
  }

  final Ref _ref;
  late final ProviderSubscription<AsyncValue<RealtimeEvent>> _events;
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
    _audio.onSourceLoaded = (ms, cached) => _loadLead.add(ms);
    _playerSub = _ref.listen<AudioPlayerState>(audioPlayerControllerProvider, _onPlayer);
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) => _sendAnchor(discontinuity: false));
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _broadcasterTick());
    _sendStart();
  }

  void stopBroadcast() => _stopBroadcasting();

  void _stopBroadcasting({String? notice}) {
    if (state.role != BroadcastRole.broadcasting) return;
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
    audio.onSourceLoaded = null;
    audio.cancelTransitionPlan();
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
    final playing = s.isPlaying && _audio.playerPlaying;
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
    final playChanged = prevS?.isPlaying != next.isPlaying;
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
  double? _planStart() {
    if (state.role != BroadcastRole.broadcasting || state.listeners == 0) return null;
    final mono = monoNowMs();
    final server = clock.serverNow(mono);
    if (server == null) return null; // hodiny neplatné -> neplánovat (N7)
    final np = _ref.read(audioPlayerControllerProvider).nowPlaying;
    if (np == null) return null;
    // Plánovaný přirozený přechod už čas startu má.
    if (_startAtServer != null && _startFor == np.recordingId && _startAtServer! > server) return _startAtServer! - clock.offsetMs!;
    final delay = plannedStartDelayMs(prepMs: _listenerPrep, oneWayMs: clock.minRtt / 2);
    _startAtServer = server + delay;
    _startFor = np.recordingId;
    _sendAnchor(discontinuity: false);
    return mono + delay;
  }

  /// Vysílač: ~20 s před koncem naplánovat přirozený přechod (K4) --
  /// jen s posluchači, platnými hodinami a mimo rádio.
  void _broadcasterTick() {
    if (state.role != BroadcastRole.broadcasting) return;
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
    _audio.planTransition(xMono: xMono, loadAtMono: loadAt(x: xMono, loadLeadMs: _loadLead.valueMs, startLeadMs: _audio.startLeadMs));
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
  double? _startScheduledFor;
  double? _transitionStartedFor;
  double? _pendingSince;
  bool _learnStartLead = false;
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

  int _prepMs() => (_listenerLoad.valueMs + _audio.startLeadMs + 100).round();

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
    _startScheduledFor = null;
    _transitionStartedFor = null;
    _pendingSince = null;
    _localPaused = false;
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
    _listenerPlayerSub?.close();
    _listenerPlayerSub = _ref.listen<AudioPlayerState>(audioPlayerControllerProvider, _onListenerPlayer);
    _startClock();
    _ref.read(realtimeClientProvider).send('broadcast.join', {'sid': b.id, 'prepMs': _prepMs()});
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _listenerTick());
  }

  String get _label => 'Stream · ${state.hostName ?? ''}';

  /// "Odejít" / "Vrátit se k mému": zpátky vlastní fronta a místo (pozastaveně).
  Future<void> leave() async {
    if (state.role != BroadcastRole.listening) return;
    final sid = state.sid;
    _ref.read(realtimeClientProvider).send('broadcast.leave', {'sid': sid});
    _tick?.cancel();
    _clockTimer?.cancel();
    _endTimer?.cancel();
    _pollActive = false;
    _listenerPlayerSub?.close();
    _listenerPlayerSub = null;
    _audio.onSourceLoaded = null;
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
    final clockId = p['clockId'] as String?;
    final gen = (p['gen'] as num?)?.toInt() ?? 0;
    final seq = (p['seq'] as num?)?.toInt() ?? 0;
    // Pořadí (clockId, gen, seq) od serveru; jiné clockId (restart API) nebo
    // odpověď na join/sync = srovnání od nuly (N1).
    final reset = p['reset'] == true || clockId != _lastClockId;
    if (!reset && (gen < _lastGen || (gen == _lastGen && seq <= _lastSeq))) return;
    if (gen != _lastGen && !reset && p['queue'] == null) {
      _askSync();
      return;
    }
    _lastClockId = clockId;
    _lastGen = gen;
    _lastSeq = seq;
    _pendingSince = null;
    final name = p['name'] as String?;
    if (name != null && name != state.hostName) state = state.copyWith(hostName: name);
    final q = p['queue'] as Map<String, dynamic>?;
    if (q != null) {
      _queue = [
        for (final i in (q['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
          if (i['id'] is String && i['t'] is String) AudioPlayerController.queueItemFromJson(i),
      ];
      _queueBase = (q['baseIndex'] as num?)?.toInt() ?? 0;
      _queueQv = (q['qv'] as num?)?.toInt() ?? 0;
      _syncPlayerQueue();
    }
    final a = p['anchor'] as Map<String, dynamic>?;
    if (a == null) return;
    final anchor = BroadcastAnchor.fromJson(a);
    if (anchor.qv != _queueQv) {
      // Kotva k frontě, kterou nemáme -- nikdy nehrát podle nesouladné fronty.
      _askSync();
      return;
    }
    if (_model.apply(anchor)) {
      _startScheduledFor = null;
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
    // Hodiny neplatné: neřídit, jen hrát dál (S4).
    if (a == null || serverNow == null || _queue.isEmpty) return;
    final audio = _audio;
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
    if (x != null && _loadedAbs == a.index && t.index == a.index && _transitionStartedFor != x && li + 1 < _queue.length && !_localPaused) {
      final xMono = x - offset;
      if (now >= loadAt(x: xMono, loadLeadMs: _listenerLoad.valueMs, startLeadMs: audio.startLeadMs)) {
        _transitionStartedFor = x;
        _startScheduledFor = x; // start nové skladby v X už je naplánovaný
        _loadedAbs = a.index + 1;
        _learnStartLead = true;
        _regulator.reset(now);
        _regulator.settle(xMono);
        unawaited(_command(() => _load(li + 1, positionMs: 0, playAtMono: xMono)));
        return;
      }
    }

    if (t.index != _loadedAbs) {
      // Jiná skladba (přeskok vysílače, připojení, výpadek): načíst a začít
      // na dopočtené pozici (plánovaný start / hned s předstihem / pozastaveně).
      _loadedAbs = t.index;
      _regulator.reset(now);
      final lead = _regulator.seekLead[false]!;
      if (t.waitingForStart) {
        final startMono = a.startAtServerMs! - offset;
        _startScheduledFor = a.startAtServerMs;
        _learnStartLead = true;
        _regulator.settle(startMono);
        unawaited(_command(() => _load(li, positionMs: t.positionMs, playAtMono: startMono)));
      } else if (t.playing && !_localPaused) {
        unawaited(_command(() => _load(li, positionMs: t.positionMs + lead)));
      } else {
        unawaited(_command(() => _load(li, positionMs: t.positionMs, playAtMono: double.infinity)));
      }
      return;
    }

    if (!audio.sourceReady) return; // načítá se / bufferuje -- cíl běží dál
    final pos = audio.exactPosition.inMicroseconds / 1000.0;
    audio.followBaseSpeed(a.rate);

    if (t.waitingForStart) {
      if (_startScheduledFor == a.startAtServerMs) return;
      _startScheduledFor = a.startAtServerMs;
      final startMono = a.startAtServerMs! - offset;
      _learnStartLead = true;
      _regulator.settle(startMono);
      unawaited(_command(() async {
        if (audio.playerPlaying) await audio.followPause();
        if ((pos - t.positionMs).abs() > 30) await audio.followSeek(Duration(milliseconds: t.positionMs.round()));
        audio.playAt(startMono);
      }));
      return;
    }
    if (!t.playing) {
      // Vysílač stojí: stát na přesném místě (play pak začne u obou stejně).
      if (audio.playerPlaying) unawaited(_command(audio.followPause));
      if ((pos - t.positionMs).abs() > 40) unawaited(_command(() => audio.followSeek(Duration(milliseconds: t.positionMs.round()))));
      return;
    }
    if (_localPaused) return;
    if (!audio.playerPlaying) {
      // Vysílač hraje, my stojíme (po pauze vysílače, po načtení): naskočit
      // s předstihem seeku.
      final lead = _regulator.seekLead[audio.currentSourceLocal]!;
      _regulator.reset(now);
      unawaited(_command(() async {
        await audio.followSeek(Duration(milliseconds: (t.positionMs + lead).round()));
        audio.playAt(now);
      }));
      return;
    }
    if (!usable) return;
    final action = _regulator.observe(nowMs: now, errorMs: pos - t.positionMs, baseRate: a.rate, cached: audio.currentSourceLocal);
    // Po plánovaném startu: zbytková chyba = chyba odhadu rozjezdu.
    final filtered = _regulator.filteredErrorMs;
    if (_learnStartLead && filtered != null) {
      _learnStartLead = false;
      audio.startLeadMs = (audio.startLeadMs + 0.5 * filtered).clamp(0, 300).toDouble();
    }
    switch (action.kind) {
      case SyncActionKind.none:
        break;
      case SyncActionKind.setRate:
        unawaited(audio.followSetRate(action.rate!).catchError((Object _) => _regulator.rateUnsupported()));
      case SyncActionKind.seek:
        unawaited(_command(() => audio.followSeek(Duration(milliseconds: (t.positionMs + action.leadMs).round()))));
    }
    if (_regulator.looseMode != state.weakSync) {
      state = state.copyWith(weakSync: _regulator.looseMode);
      _ref.read(realtimeClientProvider).send('broadcast.prep', {'prepMs': _prepMs(), 'healthy': !_regulator.looseMode});
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
    _teardown();
    _listenerPlayerSub?.close();
    _endTimer?.cancel();
    super.dispose();
  }
}
