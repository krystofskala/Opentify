import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/playlist_model.dart';
import '../../models/recording_model.dart';
import '../../state/artwork_provider.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';

final playlistDetailProvider = FutureProvider.autoDispose.family((ref, String playlistId) {
  return ref.watch(playlistsRepositoryProvider).get(playlistId);
});

/// Detail vlastního playlistu -- stejná hlavička jako Album/Interpret
/// (obal = obal první skladby), filtr/řazení/hromadný výběr a ruční
/// přeskládání dlouhým stiskem (jen v původním pořadí bez filtru -- nad
/// seřazeným/filtrovaným pohledem by přesun neměl jasný význam).
class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  final _collection = TrackCollectionController();

  // Lokální zrcadlo `detail.items` pro okamžitou (optimistickou) odezvu na
  // přetažení/odebrání -- synchronizuje se znovu, kdykoliv provider dodá
  // nová data a zrovna neprobíhá přetahování.
  List<RecordingModel>? _items;
  String? _syncedForPlaylistId;
  bool _reordering = false;

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = ref.watch(playlistDetailProvider(widget.playlistId));

    return playlist.when(
      data: (detail) {
        if (_items == null || _syncedForPlaylistId != widget.playlistId || !_reordering) {
          _items = List.of(detail.items);
          _syncedForPlaylistId = widget.playlistId;
        }
        return _buildBody(context, detail, _items!);
      },
      loading: () => const DetailLoadingScaffold(),
      error: (error, stack) => DetailErrorScaffold(
        message: 'Playlist se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(playlistDetailProvider(widget.playlistId)),
      ),
    );
  }

  Widget _buildBody(BuildContext context, PlaylistDetailModel detail, List<RecordingModel> items) {
    final first = items.isEmpty ? null : items.first;
    final cover = first == null
        ? null
        : ref.watch(recordingArtworkProvider((releaseId: first.releaseId, artistId: first.artistId))).valueOrNull;
    final totalMs = items.fold<int>(0, (sum, r) => sum + (r.durationMs ?? 0));
    final minutes = (totalMs / 60000).round();

    return ScreenAccent(
      imageUrl: cover,
      builder: (context, accent) => Scaffold(
        bottomNavigationBar: const PlayerBar(),
        body: CustomScrollView(
          slivers: [
            DetailHeroAppBar(
              title: detail.title,
              imageUrl: cover,
              accent: accent,
              eyebrow: 'Playlist',
              placeholderIcon: Symbols.queue_music_rounded,
              subtitle: [
                HeroMeta([
                  '${items.length} skladeb',
                  if (minutes > 0) '$minutes min',
                ].join(' · ')),
              ],
              actions: [
                IconButton(
                  icon: const Icon(Symbols.delete_outline_rounded),
                  tooltip: 'Smazat playlist',
                  onPressed: () => _confirmDelete(context),
                ),
              ],
            ),
            if (items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Symbols.queue_music_rounded,
                  message: 'Playlist je zatím prázdný -- přidej skladby přes „Přidat do playlistu“ '
                      'v nabídce u skladby (dlouhý stisk nebo ⋯).',
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: ListenableBuilder(
                  listenable: _collection,
                  builder: (context, _) => TrackCollectionToolbar(
                    controller: _collection,
                    allTracks: items,
                    visibleTracks: _collection.apply(items),
                    sourceLabel: detail.title,
                    onRemoveSelected: (selected) => _removeTracks(selected),
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: _collection,
                builder: (context, _) => _trackList(detail, items),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
          ],
        ),
      ),
    );
  }

  Widget _trackList(PlaylistDetailModel detail, List<RecordingModel> items) {
    final visible = _collection.apply(items);
    if (visible.isEmpty) {
      return const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Filtru nic neodpovídá.'));
    }

    TrackTile tileFor(RecordingModel r, List<RecordingModel> queue) => TrackTile(
          recording: r,
          queueRecordings: queue,
          sourceLabel: detail.title,
          selectionMode: _collection.selecting,
          selected: _collection.isSelected(r.id),
          onSelectedChanged: (value) => _collection.toggle(r.id, value),
          extraMenuActions: [
            TrackMenuAction(
              icon: Symbols.playlist_remove_rounded,
              label: 'Odebrat z playlistu',
              destructive: true,
              onSelected: () => _removeTracks([r]),
            ),
          ],
        );

    final canReorder = !_collection.isModified && !_collection.selecting;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
      sliver: canReorder
          ? SliverReorderableList(
              itemCount: visible.length,
              onReorderItem: (oldIndex, newIndex) => _onReorder(oldIndex, newIndex, items),
              itemBuilder: (context, index) => ReorderableDelayedDragStartListener(
                key: ValueKey(visible[index].id),
                index: index,
                child: tileFor(visible[index], visible),
              ),
            )
          : SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) => tileFor(visible[index], visible),
            ),
    );
  }

  Future<void> _onReorder(int oldIndex, int newIndex, List<RecordingModel> items) async {
    // `onReorderItem` už `newIndex` sám koriguje na pozici PO odebrání.
    final reordered = List.of(items);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    setState(() {
      _items = reordered;
      _reordering = true;
    });
    try {
      await ref.read(playlistsRepositoryProvider).reorderItems(widget.playlistId, reordered.map((r) => r.id).toList());
    } catch (_) {
      ref.invalidate(playlistDetailProvider(widget.playlistId));
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  Future<void> _removeTracks(List<RecordingModel> tracks) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ids = tracks.map((r) => r.id).toSet();
    setState(() {
      _items = _items?.where((r) => !ids.contains(r.id)).toList();
      _reordering = true;
    });
    try {
      final repo = ref.read(playlistsRepositoryProvider);
      for (final id in ids) {
        await repo.removeItem(widget.playlistId, id);
      }
      messenger?.showSnackBar(SnackBar(content: Text(ids.length == 1 ? 'Skladba odebrána' : '${ids.length} skladeb odebráno')));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Odebrání selhalo: $e')));
    } finally {
      ref.invalidate(myPlaylistsProvider);
      // Počkat na čerstvá data, než se zrcadlo znovu synchronizuje -- jinak
      // by odebrané skladby na okamžik naskočily zpátky.
      try {
        ref.invalidate(playlistDetailProvider(widget.playlistId));
        await ref.read(playlistDetailProvider(widget.playlistId).future);
      } catch (_) {}
      if (mounted) setState(() => _reordering = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Smazat playlist?'),
        content: const Text('Tohle nejde vrátit zpátky.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Zrušit')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Smazat')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playlistsRepositoryProvider).delete(widget.playlistId);
    ref.invalidate(myPlaylistsProvider);
    if (context.mounted) Navigator.of(context).pop();
  }
}
