import 'package:audio_service/audio_service.dart';

import 'media_session.dart';

/// Nativní appka (iOS): zamčená obrazovka, Ovládací centrum, sluchátka
/// a CarPlay přes `audio_service` (MPNowPlayingInfoCenter +
/// MPRemoteCommandCenter). Přehrává dál `just_audio` v
/// `AudioPlayerController` -- tohle jen zrcadlí stav a přeposílá tlačítka,
/// stejně jako webová verze přes Media Session API.
_Handler? _handler;

Future<void> initMediaSession() async {
  _handler ??= await AudioService.init(
    builder: _Handler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.opentify.audio',
      androidNotificationChannelName: 'Opentify',
      androidNotificationOngoing: true,
    ),
  );
}

MediaSessionBridge createMediaSessionBridge() => _NativeMediaSession();

class _Handler extends BaseAudioHandler with SeekHandler {
  void Function()? onPlay;
  void Function()? onPause;
  void Function()? onNext;
  void Function()? onPrevious;
  void Function(Duration position)? onSeek;

  @override
  Future<void> play() async => onPlay?.call();

  @override
  Future<void> pause() async => onPause?.call();

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);
}

class _NativeMediaSession implements MediaSessionBridge {
  MediaItem? _item;
  bool _playing = false;

  @override
  void setHandlers({
    required void Function() onPlay,
    required void Function() onPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function(Duration position) onSeek,
  }) {
    final h = _handler;
    if (h == null) return;
    h
      ..onPlay = onPlay
      ..onPause = onPause
      ..onNext = onNext
      ..onPrevious = onPrevious
      ..onSeek = onSeek;
  }

  @override
  void setMetadata({required String title, String? artist, String? album, String? artworkUrl}) {
    _item = MediaItem(
      id: '$title|$artist',
      title: title,
      artist: artist,
      album: album,
      artUri: artworkUrl == null ? null : Uri.tryParse(artworkUrl),
      duration: _item?.duration,
    );
    _handler?.mediaItem.add(_item);
  }

  @override
  void setPlaying(bool playing) {
    _playing = playing;
    _publish(null);
  }

  @override
  void setPosition({required Duration position, Duration? duration, double speed = 1.0}) {
    final item = _item;
    if (item != null && duration != null && item.duration != duration) {
      _item = item.copyWith(duration: duration);
      _handler?.mediaItem.add(_item);
    }
    _publish(position, speed: speed);
  }

  void _publish(Duration? position, {double speed = 1.0}) {
    final h = _handler;
    if (h == null) return;
    final previous = h.playbackState.value;
    h.playbackState.add(previous.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        _playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.skipToNext, MediaAction.skipToPrevious},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: _playing,
      updatePosition: position ?? previous.updatePosition,
      speed: _playing ? speed : 0,
    ));
  }

  @override
  void clear() {
    _item = null;
    _handler?.mediaItem.add(null);
    _handler?.playbackState.add(PlaybackState());
  }
}
