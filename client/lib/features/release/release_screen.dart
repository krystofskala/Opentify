import '../../routing/branches.dart';
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
import '../../theme/shapes.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/collection_actions.dart' show CollectionKind, showCollectionActions;
import '../../widgets/remove_from_library.dart' show confirmRemoveFromLibrary, libraryRevisionProvider;
import '../../state/library_scope.dart' show libraryIdsProvider;
import '../../widgets/track_tile.dart';
import '../../widgets/toast.dart';

final releaseProvider = FutureProvider.autoDispose.family<ReleaseModel, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getRelease(releaseId);
});

final releaseTracksProvider = FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getReleaseTracks(releaseId);
});

/// Jméno interpreta pro hlavičku (Release má jen `artistId`).
/// Skladby z jiných edic / pásek alba (`/other-editions`), po skupinách.
/// Obsazení alba (`/catalog/releases/{id}/credits`): hudebníci, autoři,
/// produkce -- kdo na čem hrál, z MusicBrainz.
final releaseCreditsProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, releaseId) {
  return ref.watch(apiClientProvider).getJson('/catalog/releases/$releaseId/credits');
});

final releaseOtherEditionsProvider =
    FutureProvider.autoDispose.family<List<({String label, List<RecordingModel> tracks})>, String>((ref, releaseId) async {
  final json = await ref.watch(apiClientProvider).getJsonList('/catalog/releases/$releaseId/other-editions');
  return [
    for (final g in json.cast<Map<String, dynamic>>())
      (
        label: g['label'] as String? ?? 'Další verze',
        tracks: [for (final t in (g['tracks'] as List<dynamic>)) RecordingModel.fromJson(t as Map<String, dynamic>)],
      ),
  ];
});

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
      showToast(messenger, '„${release.title}“ smazáno');
      if (context.mounted) context.pop();
    } catch (e) {
      showToast(messenger, 'Smazat se nepodařilo: $e');
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
      showToast(messenger, '„${release.title}“ je v knihovně');
    } catch (_) {
      showToast(messenger, 'Album se nepodařilo přidat');
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
        bottomNavigationBar: const ShellBarSpace(),
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
                // Spolupráce: každý interpret vlastní odkaz (Thile & Daves).
                if (release.credits.length > 1)
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.xs,
                    children: [for (final c in release.credits) _CreditLink(id: c.id, name: c.name)],
                  )
                else if (artistName != null)
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
              if (release.genres.isNotEmpty) SliverToBoxAdapter(child: _GenreChips(genres: release.genres)),
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
                  selectionNumber: _collection.orderOf(r.id),
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
      SliverToBoxAdapter(child: _Credits(releaseId: release.id)),
      SliverToBoxAdapter(
        child: _OtherEditions(
          releaseId: release.id,
          albumArtUrl: release.coverImageUrl,
          artistName: artistName,
          sourceLabel: release.title,
        ),
      ),
    ];
  }
}

/// "Z jiných edic a pásek": skladby, které kanonický tracklist neukazuje
/// (jiné pásky koncertu, bonusy reedic, Atmos mixy) -- schované pod
/// rozbalením, ať album zůstane přehledné, ale nic se neztratí.
class _OtherEditions extends ConsumerStatefulWidget {
  const _OtherEditions({required this.releaseId, this.albumArtUrl, this.artistName, required this.sourceLabel});

  final String releaseId;
  final String? albumArtUrl;
  final String? artistName;
  final String sourceLabel;

  @override
  ConsumerState<_OtherEditions> createState() => _OtherEditionsState();
}

class _OtherEditionsState extends ConsumerState<_OtherEditions> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(releaseOtherEditionsProvider(widget.releaseId)).valueOrNull ?? const [];
    final count = groups.fold<int>(0, (n, g) => n + g.tracks.length);
    if (count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            shape: AppShapes.md,
            leading: const Icon(Symbols.library_music_rounded),
            title: Text('Z jiných edic a pásek · $count'),
            subtitle: const Text('Bonusy reedic, jiné nahrávky koncertu, další mixy'),
            trailing: Icon(_open ? Symbols.expand_less_rounded : Symbols.expand_more_rounded),
            onTap: () => setState(() => _open = !_open),
          ),
          if (_open)
            for (final g in groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
                child: Text(g.label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              for (final (i, r) in g.tracks.indexed)
                TrackTile(
                  recording: r,
                  leadingIndex: i + 1,
                  albumArtUrl: widget.albumArtUrl,
                  artistName: widget.artistName,
                  queueRecordings: g.tracks,
                  sourceLabel: widget.sourceLabel,
                ),
            ],
        ],
      ),
    );
  }
}


/// Jeden z interpretů spolupráce -- avatar a odkaz na jeho stránku.
class _CreditLink extends ConsumerWidget {
  const _CreditLink({required this.id, required this.name});

  final String id;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = ref.watch(releaseArtistProvider(id)).valueOrNull;
    return HeroLink(
      text: name,
      avatarUrl: artist?.coverImageUrl,
      icon: Symbols.person_rounded,
      onTap: () => context.push('/artists/$id'),
    );
  }
}

/// Žánry alba -- klepnutí otevře stránku stylu.
class _GenreChips extends StatelessWidget {
  const _GenreChips({required this.genres});

  final List<String> genres;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          for (final g in genres.take(5))
            ActionChip(
              label: Text(g),
              onPressed: () => context.push('/browse/tag/${Uri.encodeComponent(g)}'),
            ),
        ],
      ),
    );
  }
}

/// Obsazení: kdo na čem hrál (a autoři, produkce). Jen když ho MusicBrainz
/// má; prvních pár hudebníků hned, zbytek po rozbalení.
class _Credits extends ConsumerStatefulWidget {
  const _Credits({required this.releaseId});

  final String releaseId;

  @override
  ConsumerState<_Credits> createState() => _CreditsState();
}

class _CreditsState extends ConsumerState<_Credits> {
  bool _all = false;

  static const _groups = [('musicians', 'Hudebníci'), ('writers', 'Autoři'), ('production', 'Produkce')];

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(releaseCreditsProvider(widget.releaseId)).valueOrNull;
    if (data == null) return const SizedBox.shrink();
    final total = (data['tracks'] as num?)?.toInt() ?? 0;
    final groups = [
      for (final (key, title) in _groups)
        (title, (data[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()),
    ].where((g) => g.$2.isNotEmpty).toList();
    if (groups.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final count = groups.fold<int>(0, (n, g) => n + g.$2.length);
    // Sbaleně: jen hudebníci (nebo první skupina), max 6 lidí.
    final shown = _all ? groups : [(groups.first.$1, groups.first.$2.take(6).toList())];

    String roles(Map<String, dynamic> p) => [
          for (final r in (p['roles'] as List<dynamic>).cast<Map<String, dynamic>>())
            // "· 7 skladeb" jen když nehrál na celém albu.
            (r['tracks'] as num) < total && total > 1
                ? '${r['label']} (${r['tracks']})'
                : r['label'] as String,
        ].join(', ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Obsazení', style: theme.textTheme.titleMedium),
          Text('Kdo na albu hrál a kdo ho vytvořil (MusicBrainz). Číslo = počet skladeb.', style: muted),
          for (final (title, people) in shown) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(title, style: theme.textTheme.titleSmall),
            for (final p in people)
              InkWell(
                borderRadius: BorderRadius.circular(AppRadii.md),
                onTap: p['artistId'] == null ? null : () => context.push('/artists/${p['artistId']}'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          p['name'] as String,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: p['artistId'] == null ? null : theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(flex: 3, child: Text(roles(p), style: muted)),
                    ],
                  ),
                ),
              ),
          ],
          if (!_all && count > shown.first.$2.length)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _all = true),
                child: Text('Zobrazit celé obsazení ($count)'),
              ),
            ),
        ],
      ),
    );
  }
}
