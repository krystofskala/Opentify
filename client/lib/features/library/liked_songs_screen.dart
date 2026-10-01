import 'package:flutter/material.dart';
import '../../widgets/collection_actions.dart' show CollectionKind, showCollectionActions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/recording_model.dart';
import '../../state/liked_songs_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';
import '../../core/cz_plural.dart';
import 'pinned_tile.dart';

const _title = 'Oblíbené skladby';

/// Srdíčko kdekoliv v appce -> seznam se hned přizpůsobí: odebrané zmizí
/// okamžitě (filtr podle živé sady), nově přidané po krátkém přenačtení.
void _listenForLikes(WidgetRef ref) {
  ref.listen(likedSongsControllerProvider, (previous, next) {
    if (previous?.valueOrNull?.length != next.valueOrNull?.length) {
      Future.delayed(const Duration(milliseconds: 600), () => ref.invalidate(likedSongsProvider));
    }
  });
}

List<RecordingModel> _liveItems(WidgetRef ref, List<RecordingModel> items) {
  final likedIds = ref.watch(likedSongsControllerProvider).valueOrNull;
  return likedIds == null ? items : items.where((r) => likedIds.contains(r.id)).toList();
}

/// Výrazná připnutá karta nahoře v Knihovně (tab Playlisty) -- tónový
/// kontejner s gradientem a srdcem, ne sklo (obsahová vrstva).
class LikedSongsCard extends ConsumerWidget {
  const LikedSongsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _listenForLikes(ref);
    final scheme = Theme.of(context).colorScheme;
    final count = ref.watch(likedSongsControllerProvider).valueOrNull?.length;
    return PinnedTile(
      icon: Symbols.favorite_rounded,
      title: 'Oblíbené',
      subtitle: count == null ? 'Playlist' : songsCount(count),
      colors: [scheme.primaryContainer, scheme.tertiaryContainer],
      iconBackground: scheme.primary,
      iconColor: scheme.onPrimary,
      textColor: scheme.onPrimaryContainer,
      onTap: () => context.push('/library/liked'),
    );
  }
}

/// Detail oblíbených skladeb -- stejná hlavička a nástrojová lišta jako
/// playlist/album.
class LikedSongsScreen extends ConsumerStatefulWidget {
  const LikedSongsScreen({super.key});

  @override
  ConsumerState<LikedSongsScreen> createState() => _LikedSongsScreenState();
}

class _LikedSongsScreenState extends ConsumerState<LikedSongsScreen> {
  final _collection = TrackCollectionController();

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  Future<void> _unlike(List<RecordingModel> tracks) async {
    final liked = ref.read(likedSongsControllerProvider.notifier);
    for (final r in tracks) {
      await liked.toggle(r.id);
    }
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
            content:
                Text(tracks.length == 1 ? 'Odebráno z oblíbených' : 'Z oblíbených odebráno: ${songsCount(tracks.length)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _listenForLikes(ref);
    final liked = ref.watch(likedSongsProvider);
    return liked.when(
      loading: () => const DetailLoadingScaffold(),
      error: (error, stack) => DetailErrorScaffold(
        message: 'Oblíbené skladby se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(likedSongsProvider),
      ),
      data: (playlist) {
        final items = _liveItems(ref, playlist.items);
        return Scaffold(
          bottomNavigationBar: const PlayerBar(),
          body: RefreshIndicator(
            onRefresh: () async => ref.invalidate(likedSongsProvider),
            child: CustomScrollView(
              slivers: [
                DetailHeroAppBar(
                  title: _title,
                  eyebrow: 'Playlist',
                  eyebrowIcon: Symbols.favorite_rounded,
                  accent: const Color(0xFFE0245E),
                  placeholderIcon: Symbols.favorite_rounded,
                  subtitle: const [HeroMeta('Všechno, co má u tebe srdíčko')],
                  meta: [
                    HeroMetaItem(Symbols.queue_music_rounded, heroTrackCount(items.length)),
                  ],
                  actions: [
                    HeroAction(
                      icon: Symbols.more_horiz_rounded,
                      tooltip: 'Další možnosti',
                      onPressed: () => showCollectionActions(
                        context,
                        kind: CollectionKind.liked,
                        id: 'liked',
                        title: _title,
                      ),
                    ),
                  ],
                ),
                ...detailContentSlivers(context, [
                  if (items.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Symbols.favorite_rounded,
                        message:
                            'Zatím nic – klepni na srdíčko u skladby, nebo naimportuj Liked Songs ze Spotify v Profilu.',
                      ),
                    )
                  else
                    ListenableBuilder(
                      listenable: _collection,
                      builder: (context, _) {
                        final visible = _collection.apply(items);
                        return SliverList.list(
                          children: [
                            TrackCollectionToolbar(
                              controller: _collection,
                              allTracks: items,
                              visibleTracks: visible,
                              sourceLabel: _title,
                              onRemoveSelected: _unlike,
                              removeLabel: 'Odebrat z oblíbených',
                            ),
                            if (visible.isEmpty) const EmptyState(compact: true, message: 'Filtru nic neodpovídá.'),
                            for (final r in visible)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                                child: TrackTile(
                                  recording: r,
                                  queueRecordings: visible,
                                  sourceLabel: _title,
                                  selectionMode: _collection.selecting,
                                  selected: _collection.isSelected(r.id),
                                  onSelectedChanged: (value) => _collection.toggle(r.id, value),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg + MediaQuery.paddingOf(context).bottom)),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}
