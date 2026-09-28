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

final releaseTracksProvider = FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, releaseId) {
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
  const ReleaseScreen({super.key, required this.releaseId, this.highlightTrackId});

  final String releaseId;

  /// Skladba, ze které se sem přišlo (klik na název skladby -- skladby
  /// nemají vlastní stránku): album k ní doscrolluje a krátce ji zvýrazní.
  final String? highlightTrackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(releaseProvider(releaseId));

    return release.when(
      data: (releaseModel) => _ReleaseBody(release: releaseModel, highlightTrackId: highlightTrackId),
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
  const _ReleaseBody({required this.release, this.highlightTrackId});

  final ReleaseModel release;
  final String? highlightTrackId;

  @override
  ConsumerState<_ReleaseBody> createState() => _ReleaseBodyState();
}

class _ReleaseBodyState extends ConsumerState<_ReleaseBody> {
  final _collection = TrackCollectionController();
  final _scroll = ScrollController();
  bool _highlightDone = false;
  bool _highlightOn = false;

  @override
  void dispose() {
    _collection.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Jednou po načtení tracklistu: doscrollovat ke skladbě (odhad podle
  /// výšky řádku -- `SliverList` dlouhé řádky dopředu nestaví) a na ~2,5 s
  /// ji podbarvit.
  void _maybeRevealHighlight(List<RecordingModel> recordings) {
    final id = widget.highlightTrackId;
    if (id == null || _highlightDone) return;
    final index = recordings.indexWhere((r) => r.id == id);
    if (index < 0) return;
    _highlightDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scroll.hasClients) return;
      final top = MediaQuery.paddingOf(context).top;
      final collapseDistance = DetailHeroAppBar.expandedHeightFor(context) - kToolbarHeight;
      const toolbarHeight = 132.0;
      const rowHeight = 60.0;
      final viewport = _scroll.position.viewportDimension;
      final target = collapseDistance + toolbarHeight + index * rowHeight - (viewport - top) * 0.35;
      setState(() => _highlightOn = true);
      await _scroll.animateTo(
        target.clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      if (mounted) setState(() => _highlightOn = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final tracks = ref.watch(releaseTracksProvider(release.id));
    final artist = ref.watch(releaseArtistProvider(release.artistId)).valueOrNull;
    final artistName = artist?.name;
    final recordings = tracks.valueOrNull;

    return ScreenAccent(
      imageUrl: release.coverImageUrl,
      builder: (context, accent) => Scaffold(
        bottomNavigationBar: const PlayerBar(),
        body: CustomScrollView(
          controller: _scroll,
          slivers: [
            DetailHeroAppBar(
              title: release.title,
              imageUrl: release.coverImageUrl,
              accent: accent,
              eyebrow: releaseTypeLabels[release.releaseType] ?? release.releaseType,
              eyebrowIcon: release.releaseType == 'single' ? Symbols.music_note_rounded : Symbols.album_rounded,
              subtitle: [
                if (artistName != null)
                  HeroLink(
                    text: artistName,
                    avatarUrl: artist?.coverImageUrl,
                    icon: Symbols.person_rounded,
                    onTap: () => context.push('/artists/${release.artistId}'),
                  ),
              ],
              meta: [
                if (release.yearLabel != '—') HeroMetaItem(Symbols.calendar_today_rounded, release.yearLabel),
                if (recordings != null) HeroMetaItem(Symbols.queue_music_rounded, heroTrackCount(recordings.length)),
                if (recordings != null && heroTotalDuration(recordings.map((r) => r.durationMs)) != null)
                  HeroMetaItem(Symbols.schedule_rounded, heroTotalDuration(recordings.map((r) => r.durationMs))!),
              ],
            ),
            ...detailContentSlivers(context, [
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
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _trackSlivers(List<RecordingModel> recordings, String? artistName) {
    final release = widget.release;
    _maybeRevealHighlight(recordings);
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
            // Album: stáhnout celé na pozadí.
            downloadWholeList: true,
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
                final tile = TrackTile(
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
                if (r.id != widget.highlightTrackId) return tile;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: _highlightOn ? 0.22 : 0),
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                  ),
                  child: tile,
                );
              },
            ),
          );
        },
      ),
    ];
  }
}
