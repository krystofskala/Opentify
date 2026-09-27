import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/audio_player_controller.dart';

/// Celoobrazovkový přehrávač po rozbalení `PlayerBar` -- inspirováno
/// PixelPlayerem (github.com/brendmung/PixelPlayer): velký zaoblený obal,
/// pozadí tónované dominantní barvou obalu (`AudioPlayerState.accentColor`,
/// stejná barva jako v `PlayerBar`/M3 tématu appky), velké ovládací prvky.
/// Bez "předchozí/další" -- kontroler zatím nemá frontu (viz
/// `AudioPlayerController`), takže by šlo o mrtvá tlačítka.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    final theme = Theme.of(context);
    final accent = playback.accentColor ?? theme.colorScheme.primary;

    if (nowPlaying == null) {
      // Teoreticky nedosažitelné (PlayerBar se schová, když nic nehraje, a
      // jen ona sem naviguje), ale bez závislosti na kontextu volajícího.
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Nic nehraje.')));
    }

    final duration = playback.duration ?? Duration.zero;
    final positionMs =
        playback.position.inMilliseconds.clamp(0, duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds);
    final isWide = MediaQuery.of(context).size.width >= 720;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (nowPlaying.artworkUrl != null)
            CachedNetworkImage(imageUrl: nowPlaying.artworkUrl!, fit: BoxFit.cover)
          else
            Container(color: accent),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                color: accent.withValues(alpha: 0.78),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 32),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Expanded(
                        child: Text(
                          'PŘEHRÁVÁ SE',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2),
                        ),
                      ),
                      const SizedBox(width: 48), // vizuálně vycentruje titulek proti šipce vlevo
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: isWide ? 480 : double.infinity),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AspectRatio(
                              aspectRatio: 1,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: nowPlaying.artworkUrl != null
                                    ? CachedNetworkImage(imageUrl: nowPlaying.artworkUrl!, fit: BoxFit.cover)
                                    : Container(
                                        color: Colors.white.withValues(alpha: 0.15),
                                        child: const Icon(Icons.music_note, color: Colors.white, size: 96),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 32),
                            Text(
                              nowPlaying.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700),
                            ),
                            if (nowPlaying.artistName != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                nowPlaying.artistName!,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 16),
                              ),
                            ],
                            const SizedBox(height: 32),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                activeTrackColor: Colors.white,
                                inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: positionMs.toDouble(),
                                max: duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds.toDouble(),
                                onChanged: duration.inMilliseconds == 0
                                    ? null
                                    : (value) => ref
                                        .read(audioPlayerControllerProvider.notifier)
                                        .seek(Duration(milliseconds: value.round())),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_formatDuration(playback.position), style: const TextStyle(color: Colors.white70)),
                                  Text(_formatDuration(duration), style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: 96,
                              height: 96,
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28)),
                                child: IconButton(
                                  icon: playback.isBuffering
                                      ? const Padding(
                                          padding: EdgeInsets.all(24),
                                          child: CircularProgressIndicator(strokeWidth: 3),
                                        )
                                      : Icon(playback.isPlaying ? Icons.pause : Icons.play_arrow, size: 48, color: accent),
                                  onPressed: playback.isBuffering
                                      ? null
                                      : () => ref.read(audioPlayerControllerProvider.notifier).togglePlayPause(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
