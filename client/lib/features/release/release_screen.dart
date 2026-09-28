import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/artist_model.dart';
import '../../models/recording_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';

final releaseProvider = FutureProvider.autoDispose.family<ReleaseModel, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getRelease(releaseId);
});

final releaseTracksProvider =
    FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getReleaseTracks(releaseId);
});

/// Jméno interpreta pro hlavičku (Release má jen `artistId`).
final releaseArtistProvider = FutureProvider.autoDispose.family<ArtistModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getArtist(artistId);
});

const releaseTypeLabels = {
  'album': 'Album',
  'ep': 'EP',
  'single': 'Singl',
  'compilation': 'Kompilace',
};

/// Detail alba: metadata + obal a tracklist jako dvě samostatná volání
/// (tracklist může chvíli trvat -- MusicBrainz release lookup).
class ReleaseScreen extends ConsumerWidget {
  const ReleaseScreen({super.key, required this.releaseId});

  final String releaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(releaseProvider(releaseId));

    return release.when(
      data: (releaseModel) => _ReleaseBody(release: releaseModel),
      loading: () => const DetailLoadingScaffold(),
      error: (error, stack) => DetailErrorScaffold(
        message: 'Album se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(releaseProvider(releaseId)),
      ),
    );
  }
}

class _ReleaseBody extends ConsumerStatefulWidget {
  const _ReleaseBody({required this.release});

  final ReleaseModel release;

  @override
  ConsumerState<_ReleaseBody> createState() => _ReleaseBodyState();
}

class _ReleaseBodyState extends ConsumerState<_ReleaseBody> {
  final _collection = TrackCollectionController();

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final tracks = ref.watch(releaseTracksProvider(release.id));
    final artistName = ref.watch(releaseArtistProvider(release.artistId)).valueOrNull?.name;
    final trackCount = tracks.valueOrNull?.length;

    return ScreenAccent(
      imageUrl: release.coverImageUrl,
      builder: (context, accent) => Scaffold(
        bottomNavigationBar: const PlayerBar(),
        body: CustomScrollView(
          slivers: [
            DetailHeroAppBar(
              title: release.title,
              imageUrl: release.coverImageUrl,
              accent: accent,
              eyebrow: releaseTypeLabels[release.releaseType] ?? release.releaseType,
              subtitle: [
                if (artistName != null)
                  HeroLink(
                    text: artistName,
                    icon: Symbols.person_rounded,
                    onTap: () => context.push('/artists/${release.artistId}'),
                  ),
                HeroMeta([
                  release.yearLabel,
                  if (trackCount != null) '$trackCount skladeb',
                ].join(' · ')),
              ],
            ),
            ...tracks.when(
              data: (recordings) => recordings.isEmpty
                  ? [
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(message: 'Tracklist se nepodařilo dohledat v MusicBrainz.'),
                      ),
                    ]
                  : _trackSlivers(recordings, artistName),
              loading: () => const [SliverToBoxAdapter(child: SkeletonTrackList(count: 8))],
              error: (error, stack) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorState(
                    message: 'Tracklist se nepodařilo načíst.',
                    error: error,
                    onRetry: () => ref.invalidate(releaseTracksProvider(release.id)),
                  ),
                ),
              ],
            ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
          ],
        ),
      ),
    );
  }

  List<Widget> _trackSlivers(List<RecordingModel> recordings, String? artistName) {
    final release = widget.release;
    return [
      SliverToBoxAdapter(
        child: ListenableBuilder(
          listenable: _collection,
          builder: (context, _) => TrackCollectionToolbar(
            controller: _collection,
            allTracks: recordings,
            visibleTracks: _collection.apply(recordings),
            sourceLabel: release.title,
            albumArtUrl: release.coverImageUrl,
            artistName: artistName,
          ),
        ),
      ),
      ListenableBuilder(
        listenable: _collection,
        builder: (context, _) {
          final visible = _collection.apply(recordings);
          if (visible.isEmpty) {
            return const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Filtru nic neodpovídá.'));
          }
          return SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
            sliver: SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final r = visible[index];
                return TrackTile(
                  recording: r,
                  leadingIndex: r.trackNumber ?? index + 1,
                  albumArtUrl: release.coverImageUrl,
                  artistName: artistName,
                  queueRecordings: visible,
                  sourceLabel: release.title,
                  selectionMode: _collection.selecting,
                  selected: _collection.isSelected(r.id),
                  onSelectedChanged: (value) => _collection.toggle(r.id, value),
                );
              },
            ),
          );
        },
      ),
    ];
  }
}
