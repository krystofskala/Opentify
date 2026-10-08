import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_event.dart';
import 'device_token.dart';

/// Klient pro `/ws` (docs/asyncapi.yaml) — jedno perzistentní spojení na
/// zařízení, s exponenciálním backoffem při výpadku a broadcast Streamem
/// pro dekódované `RealtimeEvent`.
///
/// Backend zatím ověřuje identitu jen přes `?user_id=` query param
/// (app/main.py má TODO na náhradu za `?token=<device_jwt>` z asyncapi.yaml)
/// — klient posílá obojí, aby fungoval s dnešním i budoucím backendem.
class RealtimeClient {
  RealtimeClient({required this.wsUrl, required this.userId, required this.deviceId, this.deviceName = 'Zařízení'});

  final String wsUrl;
  final String userId;
  final String deviceId;

  /// Jméno pro ostatní zařízení profilu (Opentify Connect).
  final String deviceName;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  StreamController<RealtimeEvent>? _eventsController;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;

  /// Spojení je opravdu navázané (ne jen rozjeté `connect`).
  bool _ready = false;

  /// Poslední zpráva ze serveru -- iOS po návratu z pozadí drží "otevřený"
  /// socket, který je ve skutečnosti mrtvý; podle ticha se pozná.
  DateTime _lastMessage = DateTime.now();

  static const _maxReconnectDelay = Duration(seconds: 30);

  /// Broadcast stream — víc posluchačů (playback + provisioning controller)
  /// může sledovat stejné spojení bez duplikace síťové vrstvy. Připojuje se
  /// lazy při prvním `listen`, ne při konstrukci třídy.
  Stream<RealtimeEvent> get events {
    _eventsController ??= StreamController<RealtimeEvent>.broadcast(
      onListen: connect,
    );
    return _eventsController!.stream;
  }

  void connect() {
    if (_disposed || _channel != null) return;
    // Klíč zařízení v `?t=` -- nativní appka nemá cookie a server spojení
    // bez přihlášení odmítne (živě: iPhone nedostával žádné živé zprávy).
    // `act_as`: admin jednající za jiný profil -- nativní WebSocket hlavičku
    // neumí a bez toho by Connect skončil v jiném profilu než zbytek appky.
    final uri = Uri.parse(withDeviceToken(Uri.parse(wsUrl).replace(queryParameters: {
      'user_id': userId,
      if (actAsProfile != null) 'act_as': actAsProfile!,
    }).toString()));
    try {
      final channel = WebSocketChannel.connect(uri);
      // Selhání spojení chodí i přes `stream.onError` níž (-> reconnect);
      // `ready` future by jinak skončil jako neošetřená výjimka v konzoli
      // při každém výpadku/restartu serveru.
      channel.ready.then((_) {
        if (!identical(_channel, channel)) return;
        _ready = true;
        _reconnectAttempt = 0; // backoff až po skutečném spojení
        _lastMessage = DateTime.now();
        // Představit se ostatním zařízením profilu (i po každém reconnectu).
        send('device.hello', {'deviceId': deviceId, 'name': deviceName});
        _onConnected?.call();
        for (final listener in List.of(_connectListeners)) {
          listener();
        }
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) => _ping());
      }).catchError((Object _) {});
      _channel = channel;
      _channelSub = channel.stream.listen(
        _onMessage,
        onError: (Object _, StackTrace __) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _onMessage(dynamic raw) {
    _lastMessage = DateTime.now();
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _eventsController?.add(RealtimeEvent.fromJson(decoded));
    } catch (_) {
      // Neparsovatelná/neznámá zpráva -- ignorovat, spojení kvůli tomu
      // nepadá (viz UnknownEvent pro strukturovaně neznámé, ale validní JSON).
    }
  }

  /// Hned znovu připojit (appka se vrátila do popředí -- iOS spojení na
  /// pozadí zavírá a čekat na další pokus by mohlo trvat až 30 s).
  /// `force`: i živé spojení (po přihlášení -- to staré vzniklo bez klíče).
  void reconnectNow({bool force = false}) {
    if (_disposed) return;
    if (_channel != null) {
      // Po pozadí: dlouho nic nepřišlo (server pinguje odpovědí na ping) =
      // socket je mrtvý, i když se tváří otevřeně.
      if (!force && _ready && DateTime.now().difference(_lastMessage) < const Duration(seconds: 30)) return;
      _drop();
    }
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    connect();
  }

  /// Je spojení navázané (diagnostika v seznamu zařízení).
  bool get isConnected => _ready;

  /// Udržovací ping; server odpoví `pong`. Bez odpovědi přes 70 s spojení
  /// zahodit a navázat znovu.
  void _ping() {
    if (!_ready) return;
    if (DateTime.now().difference(_lastMessage) > const Duration(seconds: 70)) {
      _handleDisconnect();
      return;
    }
    send('ping', {});
  }

  void _drop() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _ready = false;
    _channelSub?.cancel();
    _channelSub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _handleDisconnect() {
    _drop();
    if (_disposed) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempt += 1;
    final backoffSeconds = min(_maxReconnectDelay.inSeconds, pow(2, _reconnectAttempt).toInt());
    _reconnectTimer = Timer(Duration(seconds: backoffSeconds), connect);
  }

  void Function()? _onConnected;
  final List<void Function()> _connectListeners = [];

  /// Další posluchač (znovu)připojení -- vedle `onConnected` (Connect).
  void addConnectListener(void Function() listener) => _connectListeners.add(listener);

  /// Po (znovu)připojení -- Connect pošle aktuální stav přehrávání.
  set onConnected(void Function()? callback) => _onConnected = callback;

  /// Obecná zpráva (Opentify Connect: device.state, remote.command...).
  void send(String type, Map<String, dynamic> payload) => _send({'type': type, 'payload': payload});

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || !_ready) return; // stav se po připojení pošle znovu (onConnected)
    try {
      channel.sink.add(jsonEncode(message));
    } catch (_) {
      _handleDisconnect();
    }
  }

  void playbackPlay(String recordingId, {int positionMs = 0}) => _send({
        'type': 'playback.play',
        'payload': {'recordingId': recordingId, 'positionMs': positionMs},
      });

  void playbackPause() => _send({'type': 'playback.pause'});

  void playbackSeek(int positionMs) => _send({
        'type': 'playback.seek',
        'payload': {'positionMs': positionMs},
      });

  void claimActiveDevice() => _send({'type': 'device.claim_active'});

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _channelSub?.cancel();
    _channel?.sink.close();
    _eventsController?.close();
  }
}
