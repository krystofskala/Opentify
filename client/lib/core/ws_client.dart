import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/playback_model.dart';
import 'realtime_event.dart';

/// Klient pro `/ws` (docs/asyncapi.yaml) — jedno perzistentní spojení na
/// zařízení, s exponenciálním backoffem při výpadku a broadcast Streamem
/// pro dekódované `RealtimeEvent`.
///
/// Backend zatím ověřuje identitu jen přes `?user_id=` query param
/// (app/main.py má TODO na náhradu za `?token=<device_jwt>` z asyncapi.yaml)
/// — klient posílá obojí, aby fungoval s dnešním i budoucím backendem.
class RealtimeClient {
  RealtimeClient({required this.wsUrl, required this.userId, required this.deviceId});

  final String wsUrl;
  final String userId;
  final String deviceId;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  StreamController<RealtimeEvent>? _eventsController;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;

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
    final uri = Uri.parse(wsUrl).replace(queryParameters: {
      'user_id': userId,
      'token': deviceId, // placeholder dokud backend nemá reálné device JWT
    });
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _channelSub = channel.stream.listen(
        _onMessage,
        onError: (Object _, StackTrace __) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
      _reconnectAttempt = 0;
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _eventsController?.add(RealtimeEvent.fromJson(decoded));
    } catch (_) {
      // Neparsovatelná/neznámá zpráva -- ignorovat, spojení kvůli tomu
      // nepadá (viz UnknownEvent pro strukturovaně neznámé, ale validní JSON).
    }
  }

  void _handleDisconnect() {
    _channelSub?.cancel();
    _channelSub = null;
    _channel = null;
    if (_disposed) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempt += 1;
    final backoffSeconds = min(_maxReconnectDelay.inSeconds, pow(2, _reconnectAttempt).toInt());
    _reconnectTimer = Timer(Duration(seconds: backoffSeconds), connect);
  }

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return; // TODO: fronta odchozích zpráv do reconnectu
    channel.sink.add(jsonEncode(message));
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

  /// `expectedVersion` musí odpovídat serverové `PlaybackSession.version`,
  /// jinak přijde `QueueConflictEvent` místo `QueueUpdatedEvent` — volající
  /// (PlaybackController) se musí přihlásit k odběru `events` a na konflikt
  /// zareagovat přepočtem + opakováním s novou verzí.
  void queueSet(List<QueueItem> queue, int expectedVersion) => _send({
        'type': 'queue.set',
        'payload': {
          'queue': queue.map((item) => item.toJson()).toList(),
          'expectedVersion': expectedVersion,
        },
      });

  void claimActiveDevice() => _send({'type': 'device.claim_active'});

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _channelSub?.cancel();
    _channel?.sink.close();
    _eventsController?.close();
  }
}
