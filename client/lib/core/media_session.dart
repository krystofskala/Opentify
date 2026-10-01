import 'media_session_stub.dart'
    if (dart.library.js_interop) 'media_session_web.dart'
    if (dart.library.io) 'media_session_io.dart' as impl;

/// Nativní appka: zaregistrovat ovládání zamčené obrazovky (web: nic).
Future<void> initMediaSession() => impl.initMediaSession();

/// Zamčená obrazovka / Ovládací centrum / notifikace -- přes Media Session
/// API prohlížeče (iOS Safari 15+, Chrome). Bez něj iPhone ukazuje jen
/// "Opentify" bez obalu a tlačítka Další/Předchozí nefungují.
abstract class MediaSessionBridge {
  factory MediaSessionBridge() => impl.createMediaSessionBridge();

  void setHandlers({
    required void Function() onPlay,
    required void Function() onPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function(Duration position) onSeek,
  });

  void setMetadata({required String title, String? artist, String? album, String? artworkUrl});

  void setPlaying(bool playing);

  void setPosition({required Duration position, Duration? duration, double speed = 1.0});

  void clear();
}
