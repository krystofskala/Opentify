import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/playlist_model.dart';
import '../../widgets/mix_artwork.dart';
import '../wrapped/wrapped_launch_button.dart';
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
import '../../widgets/glass/glass.dart';

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
    final readOnly = detail.isReadOnly;
    final cover = detail.coverUrls.isNotEmpty
        ? detail.coverUrls.first
        : first == null
            ? null
            : ref.watch(recordingArtworkProvider((releaseId: first.releaseId, artistId: first.artistId))).valueOrNull;

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
              eyebrow: _eyebrowFor(detail.kind, detail.source),
              eyebrowIcon: _eyebrowIconFor(detail.kind, detail.source),
              placeholderIcon: _eyebrowIconFor(detail.kind, detail.source),
              subtitle: [
                if ((detail.description ?? _artistsLine(items)) case final line?) HeroMeta(line),
              ],
              meta: [
                if (detail.kind == 'CHART')
                  HeroMetaItem(Symbols.trophy_rounded, 'Top ${detail.itemCount}', emphasized: true),
                if (detail.isReadOnly && detail.generatedAt != null)
                  HeroMetaItem(Symbols.update_rounded, heroUpdatedLabel(detail.generatedAt!)),
                HeroMetaItem(Symbols.queue_music_rounded, heroTrackCount(items.length)),
                if (heroTotalDuration(items.map((r) => r.durationMs)) case final total?)
                  HeroMetaItem(Symbols.schedule_rounded, total),
              ],
              mosaicUrls: detail.coverUrls,
              // Vlastní mixy (roky, Denní mixy, mixy kategorií): stejný
              // generativní obal jako na kartě na Domů, ne fotka interpreta.
              artwork: _mixArtwork(detail),
              artworkBackdrop: _mixArtwork(detail, labels: false),
              actions: [
                if (readOnly)
                  HeroAction(
                    icon: Symbols.library_add_rounded,
                    tooltip: 'Přidat do knihovny',
                    onPressed: () => _copyToLibrary(context, detail),
                  )
                else
                  HeroAction(
                    icon: Symbols.delete_outline_rounded,
                    tooltip: 'Smazat playlist',
                    onPressed: () => _confirmDelete(context),
                  ),
              ],
            ),
            ...detailContentSlivers(context, [
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
                if (wrappedPeriodForSource(detail.source) case final period?)
                  SliverToBoxAdapter(child: WrappedLaunchCard(period: period)),
                SliverToBoxAdapter(
                  child: ListenableBuilder(
                    listenable: _collection,
                    builder: (context, _) => TrackCollectionToolbar(
                      controller: _collection,
                      allTracks: items,
                      visibleTracks: _collection.apply(items),
                      sourceLabel: detail.title,
                      onRemoveSelected: readOnly ? null : (selected) => _removeTracks(selected),
                      // Vlastní playlist: stáhnout celý na pozadí (žebříček ne --
                      // 100 skladeb najednou by zahltilo stahování).
                      downloadWholeList: !readOnly,
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: _collection,
                  builder: (context, _) => _trackList(detail, items),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
            ]),
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
            if (!detail.isReadOnly)
              TrackMenuAction(
                icon: Symbols.playlist_remove_rounded,
                label: 'Odebrat z playlistu',
                destructive: true,
                onSelected: () => _removeTracks([r]),
              ),
          ],
        );

    final canReorder = !detail.isReadOnly && !_collection.isModified && !_collection.selecting;
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
      messenger?.showSnackBar(
          SnackBar(content: Text(ids.length == 1 ? 'Skladba odebrána' : '${ids.length} skladeb odebráno')));
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

  Widget? _mixArtwork(PlaylistDetailModel detail, {bool labels = true}) {
    final source = detail.source ?? '';
    String? group;
    Color? color;
    if (source.startsWith('personal:category-mix:')) {
      final id = source.split(':').last;
      final category = ref.watch(browseCategoriesProvider).valueOrNull?.where((c) => c.id == id).firstOrNull;
      group = category?.group;
      color = category?.color;
    }
    final spec = mixArtForSource(
      source: detail.source,
      title: detail.title,
      photos: detail.coverUrls,
      color: color,
      categoryGroup: group,
    );
    return spec == null ? null : MixArtwork(spec: spec, labels: labels);
  }

  /// Štítek nad názvem -- u vlastních mixů podle zdroje (roční top skladby
  /// nejsou "Denní mix", i když jsou stejného druhu).
  String _eyebrowFor(String kind, String? source) {
    final s = source ?? '';
    if (s.startsWith('personal:year:')) return 'Top skladby roku';
    if (s.startsWith('personal:decade:')) return 'Dekáda';
    if (s.startsWith('personal:discover-weekly')) return 'Objevy týdne';
    if (s.startsWith('personal:category-mix:') ||
        s.startsWith('personal:on-repeat') ||
        s.startsWith('personal:throwback')) {
      return 'Tvůj mix';
    }
    return switch (kind) {
      'CHART' => 'Žebříček',
      'GENRE' => 'Žánr',
      'EDITORIAL' => 'Výběr',
      'PERSONAL_MIX' => 'Denní mix',
      'GENERATED_RECOMMENDATION' => 'Mix',
      _ => 'Playlist',
    };
  }

  IconData _eyebrowIconFor(String kind, String? source) {
    final s = source ?? '';
    if (s.startsWith('personal:year:') || s.startsWith('personal:decade:')) return Symbols.equalizer_rounded;
    return switch (kind) {
      'CHART' => Symbols.trending_up_rounded,
      'GENRE' => Symbols.category_rounded,
      'EDITORIAL' => Symbols.star_rounded,
      'PERSONAL_MIX' || 'GENERATED_RECOMMENDATION' => Symbols.library_music_rounded,
      _ => Symbols.queue_music_rounded,
    };
  }

  /// Bez popisu: "Interpret A, Interpret B a další" podle nejčastějších
  /// interpretů v playlistu (jako popisky mixů na Domů).
  String? _artistsLine(List<RecordingModel> items) {
    final counts = <String, int>{};
    for (final r in items) {
      final name = r.artistName;
      if (name != null && name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final top =
        (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => e.key).take(2).toList();
    return counts.length > top.length ? '${top.join(', ')} a další' : top.join(' a ');
  }

  Future<void> _copyToLibrary(BuildContext context, PlaylistDetailModel detail) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final copy = await ref.read(playlistsRepositoryProvider).copy(detail.id);
      ref.invalidate(myPlaylistsProvider);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('„${detail.title}“ přidán do knihovny'),
          action: SnackBarAction(label: 'Otevřít', onPressed: () => context.push('/playlists/${copy.id}')),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Přidání selhalo: $e')));
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
          GlassButton(
              label: 'Smazat', destructive: true, compact: true, onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playlistsRepositoryProvider).delete(widget.playlistId);
    ref.invalidate(myPlaylistsProvider);
    if (context.mounted) Navigator.of(context).pop();
  }
}
