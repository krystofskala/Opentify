import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/artwork_provider.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/net_image.dart';
import '../../core/cz_plural.dart';
import '../../widgets/glass/glass.dart';

/// Fronta přehrávání jako bottom sheet -- stejný `DraggableScrollableSheet`
/// vzor jako `showLyricsPanel` (dvě různé navigační stylizace pro dvě
/// podobné věci by byla další nekonzistence, ne řešení jedné). Rozděluje
/// `AudioPlayerState.queue` na "Právě hraje"/"Další ve frontě" kolem
/// `queueIndex`, ve stylu Finampova `queue_list.dart` -- historie (skladby
/// před `queueIndex`) se nezobrazuje, jen aktuální + co je před ní.
Future<void> showQueuePanel(BuildContext context, {required Color accentColor}) {
  return showGlassSheet(
    context,
    builder: (context) => _QueuePanel(accentColor: accentColor),
  );
}

class _QueuePanel extends ConsumerWidget {
  const _QueuePanel({required this.accentColor});
  final Color accentColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Jen fronta, ne pozice -- jinak by se celý seznam přestavoval 5x za vteřinu.
    final playback = ref.watch(audioPlayerControllerProvider
        .select((s) => (queue: s.queue, queueIndex: s.queueIndex, queueSourceLabel: s.queueSourceLabel)));

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
    final playback = ref.watch(audioPlayerControllerProvider.select((s) => (queue: s.queue, queueIndex: s.queueIndex)));
    if (playback.queue.isEmpty) {
      return const Center(child: Text('Fronta je prázdná.', style: TextStyle(color: Colors.white70)));
    }
    return _QueueList(queue: playback.queue, currentIndex: playback.queueIndex);
  }
}

class _QueueList extends ConsumerStatefulWidget {
  const _QueueList({this.scrollController, required this.queue, required this.currentIndex});

  final ScrollController? scrollController;
  final List<NowPlayingInfo> queue;
  final int currentIndex;

  @override
  ConsumerState<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<_QueueList> {
  /// Rozbalené bloky (album/playlist přidané najednou). Výchozí = sbalené:
  /// 50 skladeb jednoho alba je ve frontě jeden řádek, který jde celý odebrat
  /// (živě chtěné: "nechci mazat 50 omylem přidaných skladeb po jedné").
  final Set<String> _expanded = {};

  Widget _dismissible({
    required Key key,
    required VoidCallback onDismissed,
    required Widget child,
    String label = 'Odebrat',
  }) =>
      Dismissible(
        key: key,
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          decoration: BoxDecoration(
            color: Colors.redAccent.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Symbols.remove_circle_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        onDismissed: (_) => onDismissed(),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final queue = widget.queue;
    final currentIndex = widget.currentIndex;
    final upcomingCount = queue.length - currentIndex - 1;
    // Stálé klíče řádků (instance položky + pořadí duplicit), ne index --
    // po odebrání/přesunu se jinak přestavovaly všechny řádky pod ním
    // a posunutý řádek přeskočil bez animace.
    final seen = <int, int>{};
    final ids = [
      for (final info in queue)
        '${identityHashCode(info)}:${seen[identityHashCode(info)] = (seen[identityHashCode(info)] ?? 0) + 1}',
    ];

    return CustomScrollView(
      controller: widget.scrollController,
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
              final group = info.groupId;
              final row = _dismissible(
                key: ValueKey(ids[queueIndex]),
                onDismissed: () => controller.removeFromQueue(queueIndex),
                child: _QueueRow(
                  info: info,
                  isCurrent: false,
                  inGroup: group != null,
                  onTap: () => controller.skipToIndex(queueIndex),
                  dragIndex: i,
                ),
              );
              if (group == null) return row;

              final isStart = queueIndex == currentIndex + 1 || queue[queueIndex - 1].groupId != group;
              final expanded = _expanded.contains(group);
              if (!isStart) {
                return expanded ? row : SizedBox.shrink(key: ValueKey('hidden_${ids[queueIndex]}'));
              }
              var count = 0;
              while (queueIndex + count < queue.length && queue[queueIndex + count].groupId == group) {
                count++;
              }
              final header = _GroupHeader(
                label: info.groupLabel ?? 'Přidáno najednou',
                count: count,
                expanded: expanded,
                artworkUrl: info.artworkUrl,
                onToggle: () => setState(() => expanded ? _expanded.remove(group) : _expanded.add(group)),
                onRemove: () => controller.removeGroup(group),
              );
              if (!expanded) {
                return _dismissible(
                  key: ValueKey('group_${ids[queueIndex]}'),
                  label: 'Odebrat vše',
                  onDismissed: () => controller.removeGroup(group),
                  child: header,
                );
              }
              return Column(
                key: ValueKey('groupopen_${ids[queueIndex]}'),
                mainAxisSize: MainAxisSize.min,
                children: [header, row],
              );
            },
            onReorderItem: (oldIndex, newIndex) {
              final from = currentIndex + 1 + oldIndex;
              final to = currentIndex + 1 + newIndex;
              final group = queue[from].groupId;
              // Sbalený blok táhne celou skupinu, ne jen první skladbu.
              if (group != null && !_expanded.contains(group) && (from == currentIndex + 1 || queue[from - 1].groupId != group)) {
                var count = 0;
                while (from + count < queue.length && queue[from + count].groupId == group) {
                  count++;
                }
                controller.reorderRange(from, count, to);
              } else {
                controller.reorderQueue(from, to);
              }
            },
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
      ],
    );
  }
}

/// Hlavička bloku ve frontě: název alba/playlistu, počet skladeb, rozbalit a
/// odebrat celý blok najednou.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.onRemove,
    this.artworkUrl,
  });

  final String label;
  final int count;
  final bool expanded;
  final String? artworkUrl;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final songs = songsCount(count);
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: SizedBox.square(
                  dimension: 44,
                  child: artworkUrl != null
                      ? NetImage(url: artworkUrl!, placeholder: const _StackIcon())
                      : const _StackIcon(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '$songs · ${expanded ? 'klepnutím sbalíš' : 'klepnutím rozbalíš'}',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(expanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded, color: Colors.white70),
              IconButton(
                tooltip: 'Odebrat celý blok z fronty',
                icon: const Icon(Symbols.playlist_remove_rounded, color: Colors.white),
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StackIcon extends StatelessWidget {
  const _StackIcon();

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.white.withValues(alpha: 0.15),
        child: const Icon(Symbols.library_music_rounded, color: Colors.white, size: 20),
      );
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
  const _QueueRow({
    required this.info,
    required this.isCurrent,
    required this.onTap,
    this.dragIndex,
    this.inGroup = false,
  });

  final NowPlayingInfo info;
  final bool isCurrent;

  /// Skladba rozbaleného bloku -- odsazená pod jeho hlavičkou.
  final bool inGroup;
  final VoidCallback? onTap;
  final int? dragIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Skladby ve frontě obal nenesou (dohledá se až při přehrání) -- líně
    // přes album/interpreta, jen pro řádky, které se opravdu vykreslí.
    final artUrl = info.artworkUrl ??
        ref.watch(recordingArtworkProvider((releaseId: info.releaseId, artistId: info.artistId))).valueOrNull;
    final placeholder = Container(
      color: Colors.white.withValues(alpha: 0.15),
      child: const Icon(Symbols.music_note_rounded, color: Colors.white, size: 18),
    );
    return Material(
      color: isCurrent ? Colors.white.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            inGroup ? AppSpacing.xl : AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  // Zástupce i při načítání/chybě obrázku -- dřív prázdný
                  // čtverec od třetího řádku (design audit #12).
                  child: artUrl != null ? NetImage(url: artUrl, placeholder: placeholder) : placeholder,
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
                  // 48×48 -- holá ikona 24 px byla pro prst na iPhonu malá.
                  child: const SizedBox.square(
                    dimension: 48,
                    child: Center(child: Icon(Symbols.drag_handle_rounded, color: Colors.white54)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
