import 'media_session.dart';

Future<void> initMediaSession() async {}

MediaSessionBridge createMediaSessionBridge() => _NoopMediaSession();

class _NoopMediaSession implements MediaSessionBridge {
  @override
  void setHandlers({
    required void Function() onPlay,
    required void Function() onPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function(Duration position) onSeek,
  }) {}

  @override
  void setMetadata({required String title, String? artist, String? album, String? artworkUrl}) {}

  @override
  void setPlaying(bool playing) {}

  @override
  void setSpokenSkip({required bool spoken, void Function(Duration delta)? onSkip}) {}

  @override
  void setPosition({required Duration position, Duration? duration, double speed = 1.0}) {}

  @override
  void clear() {}
}
