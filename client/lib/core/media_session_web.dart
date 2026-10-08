import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'media_session.dart';

Future<void> initMediaSession() async {}

MediaSessionBridge createMediaSessionBridge() => _WebMediaSession();

class _WebMediaSession implements MediaSessionBridge {
  web.MediaSession? get _session {
    try {
      return web.window.navigator.mediaSession;
    } catch (_) {
      return null; // starší prohlížeč bez Media Session API
    }
  }

  void _action(String name, void Function(_ActionDetails details) handler) {
    try {
      _session?.setActionHandler(name, ((_ActionDetails details) => handler(details)).toJS);
    } catch (_) {
      // Prohlížeč akci nepodporuje (např. `seekto` na starším iOS) -- ne chyba.
    }
  }

  void Function()? _onNext;
  void Function()? _onPrevious;
  bool _spoken = false;

  @override
  void setHandlers({
    required void Function() onPlay,
    required void Function() onPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function(Duration position) onSeek,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
    _action('play', (_) => onPlay());
    _action('pause', (_) => onPause());
    if (!_spoken) {
      _action('nexttrack', (_) => onNext());
      _action('previoustrack', (_) => onPrevious());
    }
    _action('seekto', (d) {
      final seconds = d.seekTime;
      if (seconds == null) return;
      onSeek(Duration(milliseconds: (seconds * 1000).round()));
    });
    // U živého streamu (rádio, HLS) nabízel iOS na zamykací obrazovce ±10 s
    // místo další/předchozí skladby (živě nahlášeno) -- akce posunu výslovně
    // zrušit, ať zbydou jen předchozí/další.
    if (_spoken) return; // kniha: posuny místo další/předchozí (setSpokenSkip)
    for (final name in ['seekbackward', 'seekforward']) {
      try {
        _session?.setActionHandler(name, null);
      } catch (_) {}
    }
  }

  @override
  void setSpokenSkip({required bool spoken, void Function(Duration delta)? onSkip}) {
    _spoken = spoken && onSkip != null;
    if (_spoken) {
      // iOS ukáže ±30 s místo předchozí/další, když jsou akce posunu a ne skladby.
      for (final name in ['nexttrack', 'previoustrack']) {
        try {
          _session?.setActionHandler(name, null);
        } catch (_) {}
      }
      _action('seekbackward', (d) => onSkip!(-Duration(milliseconds: ((d.seekOffset ?? 30) * 1000).round())));
      _action('seekforward', (d) => onSkip!(Duration(milliseconds: ((d.seekOffset ?? 30) * 1000).round())));
      return;
    }
    for (final name in ['seekbackward', 'seekforward']) {
      try {
        _session?.setActionHandler(name, null);
      } catch (_) {}
    }
    if (_onNext != null) _action('nexttrack', (_) => _onNext!());
    if (_onPrevious != null) _action('previoustrack', (_) => _onPrevious!());
  }

  @override
  void setMetadata({required String title, String? artist, String? album, String? artworkUrl}) {
    final session = _session;
    if (session == null) return;
    try {
      session.metadata = web.MediaMetadata(
        web.MediaMetadataInit(
          title: title,
          artist: artist ?? '',
          album: album ?? '',
          artwork: [
            if (artworkUrl != null) web.MediaImage(src: artworkUrl, sizes: '512x512'),
            web.MediaImage(src: 'icons/Icon-512.png', sizes: '512x512', type: 'image/png'),
          ].toJS,
        ),
      );
    } catch (_) {}
  }

  @override
  void setPlaying(bool playing) {
    try {
      _session?.playbackState = playing ? 'playing' : 'paused';
    } catch (_) {}
  }

  @override
  void setPosition({required Duration position, Duration? duration, double speed = 1.0}) {
    if (duration == null || duration <= Duration.zero) return;
    final seconds = duration.inMilliseconds / 1000;
    final at = (position.inMilliseconds / 1000).clamp(0, seconds);
    try {
      _session?.setPositionState(
        web.MediaPositionState(duration: seconds, playbackRate: speed, position: at),
      );
    } catch (_) {}
  }

  @override
  void clear() {
    try {
      _session?.metadata = null;
      _session?.playbackState = 'none';
    } catch (_) {}
  }
}

/// Detail akce Media Session (`seekto` nese čas) -- balíček `web` 1.x tenhle
/// typ už nemá.
extension type _ActionDetails._(JSObject _) implements JSObject {
  external double? get seekTime;
  external double? get seekOffset;
}
