import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';

import '../core/ws_client.dart';
import 'providers.dart';

/// Metadata skladby pro zobrazení v `PlayerBar` -- na rozdíl od `models/`
/// (1:1 se schématy z docs/openapi.yaml) je tohle čistě lokální UI konstrukt,
/// sestavovaný z toho, co má volající po ruce (album, interpret) v okamžiku
/// kliknutí na "přehrát", ne ze samostatného API volání.
class NowPlayingInfo {
  const NowPlayingInfo({required this.recordingId, required this.title, this.artistName, this.artworkUrl});

  final String recordingId;
  final String title;
  final String? artistName;
  final String? artworkUrl;
}

class AudioPlayerState {
  const AudioPlayerState({
    this.nowPlaying,
    required this.isPlaying,
    required this.isBuffering,
    required this.position,
    this.duration,
    this.error,
    this.accentColor,
  });

  const AudioPlayerState.idle()
      : nowPlaying = null,
        isPlaying = false,
        isBuffering = false,
        position = Duration.zero,
        duration = null,
        error = null,
        accentColor = null;

  final NowPlayingInfo? nowPlaying;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration? duration;
  final String? error;

  /// Dominantní/vibrantní barva z obalu právě hrající skladby (viz
  /// `AudioPlayerController._extractAccentColor`) -- pohání "PixelPlay"
  /// dynamické zabarvení `PlayerBar` a M3 seed appky v `app.dart`. `null`,
  /// dokud se obal nestáhne/nezanalyzuje, nebo když skladba žádný obal nemá.
  final Color? accentColor;

  AudioPlayerState copyWith({
    NowPlayingInfo? nowPlaying,
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? duration,
    String? error,
    Color? accentColor,
  }) {
    return AudioPlayerState(
      nowPlaying: nowPlaying ?? this.nowPlaying,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      error: error,
      accentColor: accentColor ?? this.accentColor,
    );
  }
}

/// Skutečné (lokální) přehrávání zvuku přes `just_audio` -- na rozdíl od
/// `state/playback_controller.dart` (který jen zrcadlí `playback.*`/`queue.*`
/// WS protokol pro budoucí multi-device sync, viz jeho dokumentační komentář)
/// tenhle kontroler je to, co dnes skutečně pouští zvuk v prohlížeči/na
/// zařízení. Zůstává informovat `RealtimeClient` o play/pause/seek, aby
/// ostatní zařízení -- až server `playback.*` doimplementuje -- viděla
/// stejný stav; dokud server tyhle zprávy nezpracovává, jde jen o no-op
/// odeslání navíc.
class AudioPlayerController extends StateNotifier<AudioPlayerState> {
  AudioPlayerController(this._realtime) : super(const AudioPlayerState.idle()) {
    _configureSession();
    _player.playerStateStream.listen(_onPlayerStateChanged);
    _player.positionStream.listen((position) => state = state.copyWith(position: position));
    _player.durationStream.listen((duration) => state = state.copyWith(duration: duration));
  }

  final RealtimeClient _realtime;
  final AudioPlayer _player = AudioPlayer();

  Future<void> _configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  Future<void> playTrack(NowPlayingInfo info, String streamUrl) async {
    state = AudioPlayerState(
      nowPlaying: info,
      isPlaying: false,
      isBuffering: true,
      position: Duration.zero,
      duration: null,
      accentColor: null,
    );
    if (info.artworkUrl != null) {
      unawaited(_extractAccentColor(info.recordingId, info.artworkUrl!));
    }
    try {
      // `play()` musí padnout do stejného synchronního běhu jako uživatelův
      // klik, jinak ho prohlížečová autoplay politika ztiší -- `setUrl` dělá
      // reálný síťový požadavek, takže na jeho dokončení nečekáme před
      // voláním `play()` (just_audio start přehrávání sám odloží, dokud
      // zdroj nenačte).
      final durationFuture = _player.setUrl(streamUrl);
      unawaited(_player.play());
      await durationFuture;
      _realtime.playbackPlay(info.recordingId);
    } catch (e) {
      state = state.copyWith(isBuffering: false, error: '$e');
    }
  }

  /// Vibrantní/dominantní barva obalu pro "PixelPlay" dynamické zabarvení UI
  /// (viz `AudioPlayerState.accentColor`). Kontroluje `recordingId` proti
  /// aktuálnímu stavu, aby pozdě doběhnuvší extrakce ze staré skladby
  /// nepřepsala barvu té, na kterou uživatel mezitím přepnul.
  Future<void> _extractAccentColor(String recordingId, String artworkUrl) async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(artworkUrl),
        size: const Size(120, 120),
        maximumColorCount: 16,
      );
      if (state.nowPlaying?.recordingId != recordingId) return;
      final color = palette.vibrantColor?.color ??
          palette.dominantColor?.color ??
          palette.mutedColor?.color;
      if (color != null) {
        state = state.copyWith(accentColor: color);
      }
    } catch (_) {
      // Obal se nepodařilo stáhnout/zanalyzovat -- necháme výchozí barvu appky.
    }
  }

  Future<void> togglePlayPause() async {
    if (state.nowPlaying == null) return;
    if (_player.playing) {
      await _player.pause();
      _realtime.playbackPause();
    } else {
      await _player.play();
      _realtime.playbackPlay(state.nowPlaying!.recordingId, positionMs: state.position.inMilliseconds);
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _realtime.playbackSeek(position.inMilliseconds);
  }

  void _onPlayerStateChanged(PlayerState playerState) {
    state = state.copyWith(
      isPlaying: playerState.playing,
      isBuffering: playerState.processingState == ProcessingState.loading ||
          playerState.processingState == ProcessingState.buffering,
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

final audioPlayerControllerProvider = StateNotifierProvider<AudioPlayerController, AudioPlayerState>((ref) {
  return AudioPlayerController(ref.watch(realtimeClientProvider));
});
