import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/artwork_provider.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/net_image.dart';

/// Fronta přehrávání jako bottom sheet -- stejný `DraggableScrollableSheet`
/// vzor jako `showLyricsPanel` (dvě různé navigační stylizace pro dvě
/// podobné věci by byla další nekonzistence, ne řešení jedné). Rozděluje
/// `AudioPlayerState.queue` na "Právě hraje"/"Další ve frontě" kolem
/// `queueIndex`, ve stylu Finampova `queue_list.dart` -- historie (skladby
/// před `queueIndex`) se nezobrazuje, jen aktuální + co je před ní.
Future<void> showQueuePanel(BuildContext context, {required Color accentColor}) {
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _QueuePanel(accentColor: accentColor),
  );
}

class _QueuePanel extends ConsumerWidget {
  const _QueuePanel({required this.accentColor});
  final Color accentColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(audioPlayerControllerProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
        child: GlassContainer.frosted(
          // Stejné hustě namrzlé, skladbou tónované sklo jako přehrávač pod ním.
          borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
          tint: accentColor,
          fit: StackFit.expand,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 14),
              Text(
                playback.queueSourceLabel != null
                    ? 'PŘEHRÁVÁNO Z ${playback.queueSourceLabel!.toUpperCase()}'
                    : 'FRONTA',
                style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: playback.queue.isEmpty
                    ? const Center(child: Text('Fronta je prázdná.', style: TextStyle(color: Colors.white70)))
                    : _QueueList(
                        scrollController: scrollController,
                        queue: playback.queue,
                        currentIndex: playback.queueIndex,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fronta bez obalu -- druhý sloupec velkého přehrávače na PC.
class QueueView extends ConsumerWidget {
  const QueueView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(audioPlayerControllerProvider);
    if (playback.queue.isEmpty) {
      return const Center(child: Text('Fronta je prázdná.', style: TextStyle(color: Colors.white70)));
    }
    return _QueueList(queue: playback.queue, currentIndex: playback.queueIndex);
  }
}

class _QueueList extends ConsumerWidget {
  const _QueueList({this.scrollController, required this.queue, required this.currentIndex});

  final ScrollController? scrollController;
  final List<NowPlayingInfo> queue;
  final int currentIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final upcomingCount = queue.length - currentIndex - 1;

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        if (currentIndex >= 0) ...[
          const SliverToBoxAdapter(child: _SectionLabel('Právě hraje')),
          SliverToBoxAdapter(child: _QueueRow(info: queue[currentIndex], isCurrent: true, onTap: null)),
        ],
        if (upcomingCount > 0) ...[
          const SliverToBoxAdapter(child: _SectionLabel('Další ve frontě')),
          SliverReorderableList(
            itemCount: upcomingCount,
            itemBuilder: (context, i) {
              final queueIndex = currentIndex + 1 + i;
              final info = queue[queueIndex];
              return _QueueRow(
                key: ValueKey('${info.recordingId}_$queueIndex'),
                info: info,
                isCurrent: false,
                onTap: () => controller.skipToIndex(queueIndex),
                dragIndex: i,
              );
            },
            onReorderItem: (oldIndex, newIndex) {
              controller.reorderQueue(currentIndex + 1 + oldIndex, currentIndex + 1 + newIndex);
            },
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxs),
        child: Text(
          text,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontWeight: FontWeight.w700),
        ),
      );
}

class _QueueRow extends ConsumerWidget {
  const _QueueRow({super.key, required this.info, required this.isCurrent, required this.onTap, this.dragIndex});

  final NowPlayingInfo info;
  final bool isCurrent;
  final VoidCallback? onTap;
  final int? dragIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Skladby ve frontě obal nenesou (dohledá se až při přehrání) -- líně
    // přes album/interpreta, jen pro řádky, které se opravdu vykreslí.
    final artUrl = info.artworkUrl ??
        ref.watch(recordingArtworkProvider((releaseId: info.releaseId, artistId: info.artistId))).valueOrNull;
    return Material(
      color: isCurrent ? Colors.white.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: artUrl != null
                      ? NetImage(url: artUrl)
                      : Container(
                          color: Colors.white.withValues(alpha: 0.15),
                          child: const Icon(Symbols.music_note_rounded, color: Colors.white, size: 18),
                        ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white, fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500),
                    ),
                    if (info.artistName != null)
                      Text(
                        info.artistName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                      ),
                  ],
                ),
              ),
              if (isCurrent)
                const Icon(Symbols.graphic_eq_rounded, color: Colors.white, size: 18)
              else if (dragIndex != null)
                ReorderableDragStartListener(
                  index: dragIndex!,
                  child: const Icon(Symbols.drag_handle_rounded, color: Colors.white54),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
