import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/share_link.dart';
import '../../models/artist_model.dart';
import '../../models/recording_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/collection_actions.dart' show CollectionKind, showCollectionActions;
import '../../widgets/remove_from_library.dart' show confirmRemoveFromLibrary, libraryRevisionProvider;
import '../../state/library_scope.dart' show libraryIdsProvider;
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

  /// ⋯ › Smazat album -- jen alba přidaná z YouTube / ručně.
  Future<void> _deleteImported(BuildContext context, ReleaseModel release) async {
    final ok = await showGlassSheet<bool>(
      context,
      builder: (sheet) => GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Smazat „${release.title}“?', style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Album zmizí z diskografie i z knihovny a stažené soubory se smažou. Historie poslechů zůstane.',
                style: Theme.of(sheet).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              GlassButton(
                label: 'Smazat album',
                icon: Symbols.delete_rounded,
                destructive: true,
                expand: true,
                onPressed: () => Navigator.of(sheet).pop(true),
              ),
              const SizedBox(height: AppSpacing.xs),
              GlassButton(
                label: 'Zrušit',
                style: GlassButtonStyle.plain,
                expand: true,
                onPressed: () => Navigator.of(sheet).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(apiClientProvider).deleteJson('/library/imported-releases/${release.id}');
      ref.read(libraryRevisionProvider.notifier).state++;
      messenger?.showSnackBar(SnackBar(content: Text('„${release.title}“ smazáno')));
      if (context.mounted) context.pop();
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Smazat se nepodařilo: $e')));
    }
  }

  /// Hlavní akce hlavičky: celé album do knihovny / z ní.
  Future<void> _toggleLibrary(
      BuildContext context, ReleaseModel release, List<RecordingModel>? recordings, bool inLibrary) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (inLibrary) {
      if (recordings != null) await confirmRemoveFromLibrary(context, recordings);
      return;
    }
    try {
      await ref.read(apiClientProvider).postJson('/library/albums/${release.id}');
      ref.read(libraryRevisionProvider.notifier).state++;
      messenger?.showSnackBar(SnackBar(content: Text('„${release.title}“ je v knihovně')));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text('Album se nepodařilo přidat')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final tracks = ref.watch(releaseTracksProvider(release.id));
    // Tracklist z Deezeru album často teprve dohledá a uloží mu i obal --
    // bez obalu tedy po načtení tracklistu album jednou načíst znovu (dřív
    // se obal ukázal až při další návštěvě).
    ref.listen(releaseTracksProvider(release.id), (previous, next) {
      if (release.coverImageUrl == null && next.hasValue && !(previous?.hasValue ?? false)) {
        ref.invalidate(releaseProvider(release.id));
      }
    });
    final artist = ref.watch(releaseArtistProvider(release.artistId)).valueOrNull;
    final artistName = artist?.name;
    final recordings = tracks.valueOrNull;
    final ShareTarget albumShare = (kind: 'releases', id: release.id);
    ref.watch(shareLinkProvider(albumShare)); // přednačíst (Safari sdílí jen hned po klepnutí)
    // Je celé album v knihovně? (všechny jeho skladby)
    final libraryIds = ref.watch(libraryIdsProvider).valueOrNull;
    final inLibrary = recordings != null &&
        recordings.isNotEmpty &&
        libraryIds != null &&
        recordings.every((r) => libraryIds.contains(r.id));

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
              ],
              // Audit UI: jen hlavní „uložit" + ⋯ (dřív 4 nepopsaná kolečka --
              // klepnutí na rádio trefovalo i sousední „Na později").
              actions: [
                HeroAction(
                  icon: inLibrary ? Symbols.library_add_check_rounded : Symbols.library_add_rounded,
                  tooltip: inLibrary ? 'V knihovně' : 'Přidat do knihovny',
                  onPressed: () => _toggleLibrary(context, release, recordings, inLibrary),
                ),
                HeroAction(
                  icon: Symbols.more_horiz_rounded,
                  tooltip: 'Další možnosti',
                  onPressed: () => showCollectionActions(
                    context,
                    kind: CollectionKind.album,
                    id: release.id,
                    title: release.title,
                    subtitle: artistName,
                    imageUrl: release.coverImageUrl,
                    artistId: release.artistId,
                    artistName: artistName,
                    inLibrary: inLibrary,
                    onDelete: release.imported ? () => _deleteImported(context, release) : null,
                  ),
                ),
              ],
            ),
            ...detailContentSlivers(context, [
              if (release.notes != null) SliverToBoxAdapter(child: HeroTeaser(text: release.notes!)),
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
