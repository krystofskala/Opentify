import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/audio_player_controller.dart';
import '../theme/accent_color.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'net_image.dart';

/// PixelPlayerova "bublinová" `RecentlyPlayedPill` (viz `RecentlyPlayedSection.kt`)
/// -- kapslový tvar (58dp vysoký, poloměr = polovina výšky), kruhový obal
/// vlevo, titulek+interpret vedle, celá pilulka podbarvená barvou VLASTNÍHO
/// obalu (ne barvou právě hrající skladby -- každá bublina má svou náladu).
/// Poloměr morphuje z pilulky na `AppRadii.md`, když je tahle skladba právě
/// ta hrající -- stejný motiv jako `TrackTile`.
class RecentlyPlayedPill extends ConsumerWidget {
  const RecentlyPlayedPill({super.key, required this.info, required this.queue, this.width = 210});

  final NowPlayingInfo info;

  /// Celá "naposledy přehráno" historie -- umožní Předchozí/Další mezi
  /// bublinami, stejně jako jinde `queueRecordings`.
  final List<NowPlayingInfo> queue;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isPlaying = ref.watch(
      audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId == info.recordingId),
    );
    final accent = info.artworkUrl != null
        ? ref.watch(screenAccentColorProvider(info.artworkUrl!)).valueOrNull
        : null;
    final container = accent ?? theme.colorScheme.surfaceContainerHigh;
    final onContainer = ThemeData.estimateBrightnessForColor(container) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    final radius = isPlaying ? AppRadii.md : AppRadii.pill;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      width: width,
      height: 58,
      decoration: ShapeDecoration(color: container, shape: AppShapes.of(radius)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: AppShapes.of(radius),
          onTap: () {
            final index = queue.indexWhere((q) => q.recordingId == info.recordingId);
            ref.read(audioPlayerControllerProvider.notifier).playQueue(
                  queue,
                  index < 0 ? 0 : index,
                  sourceLabel: 'Naposledy přehráno',
                );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: info.artworkUrl != null
                        ? NetImage(url: info.artworkUrl!)
                        : Container(
                            color: onContainer.withValues(alpha: 0.15),
                            child: Icon(Symbols.music_note_rounded, size: 16, color: onContainer),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: AppFontSize.small, color: onContainer),
                      ),
                      if (info.artistName != null)
                        Text(
                          info.artistName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: AppFontSize.tiny, color: onContainer.withValues(alpha: 0.7)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
