import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/audio_player_controller.dart';

/// Perzistentní "Liquid Glass" lišta přehrávače -- rozostřený obal alba na
/// pozadí, přes něj poloprůhledná skleněná vrstva (`BackdropFilter`). Vkládá
/// se do `bottomNavigationBar` slotu na každé obrazovce, kde má být vidět
/// (viz `HomeShell`, `ReleaseScreen`, `ArtistScreen`). Když nic nehraje,
/// nezabírá žádné místo.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    if (nowPlaying == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final accent = playback.accentColor ?? theme.colorScheme.primary;
    final duration = playback.duration ?? Duration.zero;
    final positionMs = playback.position.inMilliseconds
        .clamp(0, duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          children: [
            if (nowPlaying.artworkUrl != null)
              Positioned.fill(
                child: CachedNetworkImage(
                    imageUrl: nowPlaying.artworkUrl!, fit: BoxFit.cover),
              )
            else
              Positioned.fill(child: Container(color: accent)),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.55),
                      ],
                    ),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.14)),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Neinteraktivní ukazatel -- jen "at a glance" průběh, žádný
                  // Slider. Flutterí Slider si i přes vizuálně tenký track
                  // (trackHeight: 2) drží dotykovou plochu ~40dp vysokou, což
                  // v týhle 8px liště kradlo tapy určené pro rozbalení Now
                  // Playing pod ním -- klik na řádek dole místo expandu
                  // omylem seekoval skladbu. Reálný seek slider zůstává jen
                  // v `NowPlayingScreen`, přesně jak to řeší PixelPlayer.
                  SizedBox(
                    height: 3,
                    child: duration.inMilliseconds == 0
                        ? (playback.isBuffering
                            ? const LinearProgressIndicator(
                                minHeight: 3,
                                backgroundColor: Colors.transparent)
                            : const SizedBox.shrink())
                        : LinearProgressIndicator(
                            value: positionMs / duration.inMilliseconds,
                            minHeight: 3,
                            backgroundColor: Colors.white.withValues(alpha: 0.25),
                            valueColor: const AlwaysStoppedAnimation(Colors.white),
                          ),
                  ),
                  InkWell(
                    // Klik kdekoliv na řádek (mimo samotné tlačítko play/pause
                    // vpravo, které si tap vezme samo) rozbalí celoobrazovkový
                    // přehrávač -- "nejde zvětšit" byl reálný nedostatek dřívější
                    // verze, PixelPlayer to řeší přesně takhle (mini bar -> Now Playing).
                    onTap: () => context.push('/now-playing'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: nowPlaying.artworkUrl != null
                                  ? CachedNetworkImage(
                                      imageUrl: nowPlaying.artworkUrl!,
                                      fit: BoxFit.cover)
                                  : Container(
                                      color:
                                          Colors.white.withValues(alpha: 0.15),
                                      child: const Icon(Icons.music_note,
                                          color: Colors.white, size: 20),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  nowPlaying.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600),
                                ),
                                if (nowPlaying.artistName != null)
                                  Text(
                                    nowPlaying.artistName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.75),
                                        fontSize: 12),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: playback.isBuffering
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : Icon(
                                    playback.isPlaying
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_filled,
                                    color: Colors.white,
                                    size: 38,
                                  ),
                            onPressed: playback.isBuffering
                                ? null
                                : () => ref
                                    .read(
                                        audioPlayerControllerProvider.notifier)
                                    .togglePlayPause(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
