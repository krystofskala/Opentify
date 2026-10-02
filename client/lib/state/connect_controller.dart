import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/realtime_event.dart';
import 'audio_player_controller.dart';
import 'providers.dart';
import 'package:flutter/widgets.dart';

/// Jiné zařízení stejného profilu (Opentify Connect).
class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.name,
    this.title,
    this.artist,
    this.artworkUrl,
    this.isPlaying = false,
    this.positionMs = 0,
    this.durationMs,
  });

  final String id;
  final String name;
  final String? title;
  final String? artist;
  final String? artworkUrl;
  final bool isPlaying;
  final int positionMs;
  final int? durationMs;

  bool get hasTrack => title != null;

  factory RemoteDevice.fromJson(Map<String, dynamic> j) {
    final np = j['nowPlaying'] as Map<String, dynamic>?;
    return RemoteDevice(
      id: j['deviceId'] as String,
      name: j['name'] as String? ?? 'Zařízení',
      title: np?['title'] as String?,
      artist: np?['artist'] as String?,
      artworkUrl: np?['artworkUrl'] as String?,
      isPlaying: j['isPlaying'] as bool? ?? false,
      positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (j['durationMs'] as num?)?.toInt(),
    );
  }
}

/// Opentify Connect (jako Spotify Connect): ostatní zařízení profilu, co na
/// nich hraje, ovládání na dálku a převzetí přehrávání. Server viz
/// backend app/realtime.py.
final connectProvider = StateNotifierProvider<ConnectController, List<RemoteDevice>>((ref) => ConnectController(ref));

/// Zařízení, které právě hraje (jiné než tohle) -- lišta "Hraje na…".
final remotePlayingProvider = Provider<RemoteDevice?>((ref) {
  return ref.watch(connectProvider).where((d) => d.isPlaying && d.hasTrack).firstOrNull;
});

class ConnectController extends StateNotifier<List<RemoteDevice>> with WidgetsBindingObserver {
  ConnectController(this._ref) : super(const []) {
    WidgetsBinding.instance.addObserver(this);
    final client = _ref.read(realtimeClientProvider);
    client.onConnected = () => _publish(force: true);
    _events = _ref.listen<AsyncValue<RealtimeEvent>>(realtimeEventsProvider, (_, next) {
      final event = next.valueOrNull;
      if (event is ConnectEvent) _onEvent(event);
    });
    _player = _ref.listen<AudioPlayerState>(audioPlayerControllerProvider, (prev, next) {
      final changed = prev?.nowPlaying?.recordingId != next.nowPlaying?.recordingId ||
          prev?.isPlaying != next.isPlaying;
      if (changed) _publish(force: true);
    });
    // Pozice občas (ať je na ostatních zařízeních vidět, kde skladba je).
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _publish());
  }

  final Ref _ref;
  late final ProviderSubscription<AsyncValue<RealtimeEvent>> _events;
  late final ProviderSubscription<AudioPlayerState> _player;
  late final Timer _tick;

  void _publish({bool force = false}) {
    final s = _ref.read(audioPlayerControllerProvider);
    final np = s.nowPlaying;
    if (!force && !s.isPlaying) return;
    _ref.read(realtimeClientProvider).send('device.state', {
      'nowPlaying': np == null
          ? null
          : {'recordingId': np.recordingId, 'title': np.title, 'artist': np.artistName, 'artworkUrl': np.artworkUrl},
      'isPlaying': s.isPlaying,
      'positionMs': s.position.inMilliseconds,
      'durationMs': s.duration?.inMilliseconds,
      'sourceLabel': s.queueSourceLabel,
    });
  }

  void _onEvent(ConnectEvent e) {
    final audio = _ref.read(audioPlayerControllerProvider.notifier);
    switch (e.type) {
      case 'devices.update':
        final all = (e.payload['devices'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
        state = [
          for (final d in all)
            if (d['deviceId'] != AppConfig.deviceId) RemoteDevice.fromJson(d),
        ];
      case 'remote.command':
        switch (e.payload['action']) {
          case 'play':
            unawaited(audio.resumeIfPaused());
          case 'pause':
            unawaited(audio.pauseIfPlaying());
          case 'toggle':
            unawaited(audio.togglePlayPause());
          case 'next':
            unawaited(audio.next());
          case 'previous':
            unawaited(audio.previous());
          case 'seek':
            final ms = (e.payload['value'] as num?)?.toInt();
            if (ms != null) unawaited(audio.seek(Duration(milliseconds: ms)));
        }
      case 'handoff.request':
        // Jiné zařízení přebírá: pošli mu frontu a místo, sám ztichni.
        final snapshot = audio.handoffSnapshot();
        final to = e.payload['from'] as String?;
        if (snapshot == null || to == null) return;
        _ref.read(realtimeClientProvider).send('handoff.state', {'to': to, 'state': snapshot});
        unawaited(audio.pauseIfPlaying());
      case 'handoff.state':
        final snapshot = e.payload['state'] as Map<String, dynamic>?;
        if (snapshot != null) unawaited(audio.resumeFromHandoff(snapshot));
    }
  }

  /// Povel jinému zařízení (play / pause / toggle / next / previous / seek).
  void command(String deviceId, String action, {Object? value}) {
    _ref.read(realtimeClientProvider).send('remote.command', {
      'target': deviceId,
      'action': action,
      if (value != null) 'value': value,
    });
  }

  /// "Přehrát tady": převzít frontu a místo z jiného zařízení.
  void takeOver(String deviceId) {
    _ref.read(realtimeClientProvider).send('handoff.request', {'target': deviceId});
  }

  /// "Přehrát na X": poslat tohle přehrávání na jiné zařízení. Cíl si o stav
  /// požádá sám -- tady jen řekneme, ať převezme od nás.
  void sendTo(String deviceId) {
    final snapshot = _ref.read(audioPlayerControllerProvider.notifier).handoffSnapshot();
    if (snapshot == null) return;
    _ref.read(realtimeClientProvider).send('handoff.state', {'to': deviceId, 'state': snapshot});
    unawaited(_ref.read(audioPlayerControllerProvider.notifier).pauseIfPlaying());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle != AppLifecycleState.resumed) return;
    final client = _ref.read(realtimeClientProvider);
    if (client.isConnected) {
      _publish(force: true);
      client.send('devices.list', {});
    } else {
      client.reconnectNow(); // hello + stav pošle onConnected
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events.close();
    _player.close();
    _tick.cancel();
    super.dispose();
  }
}
