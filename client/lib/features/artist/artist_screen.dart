import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/listen_later_repository.dart' show LaterKind;
import '../../models/artist_bio_model.dart';
import '../../state/listen_later_controller.dart';
import '../../models/discography_model.dart';
import '../../models/recording_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/media_card.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/playlist_card.dart' show RankBadge;
import '../../widgets/queue_action_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';
import '../release/release_screen.dart' show releaseTracksProvider;

final discographyProvider = FutureProvider.autoDispose.family<DiscographyModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getDiscography(artistId);
});

/// Životopis/podobní interpreti chodí z Wikidata/Wikipedie -- samostatně,
/// ať na ně nečeká tracklist/diskografie z lokální DB.
final artistBioProvider = FutureProvider.autoDispose.family<ArtistBioModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getArtistBio(artistId);
});

final artistRaritiesProvider =
    FutureProvider.autoDispose.family<List<({ReleaseModel release, String rarity})>, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getRarities(artistId);
});

const _releaseTypeLabels = {
  'album': 'Alba',
  'ep': 'EP',
  'single': 'Singly',
  'compilation': 'Kompilace',
};

/// "1963–2023" z dat vydání (jen rok, jedno vydání -> jen ten rok).
String? _activeYears(List<ReleaseModel> releases) {
  final years = releases
      .map((r) =>
          r.releaseDate == null || r.releaseDate!.length < 4 ? null : int.tryParse(r.releaseDate!.substring(0, 4)))
      .whereType<int>()
      .toList();
  if (years.isEmpty) return null;
  years.sort();
  return years.first == years.last ? '${years.first}' : '${years.first}–${years.last}';
}

/// Profil interpreta: hlavička, skladby z nejnovějšího vydání, životopis,
/// podobní interpreti a diskografie rozdělená podle typu vydání.
class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({super.key, required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discography = ref.watch(discographyProvider(artistId));

    return discography.when(
      data: (data) => _ArtistBody(discography: data),
      loading: () => const DetailLoadingScaffold(),
      error: (error, stack) => DetailErrorScaffold(
        message: 'Interpreta se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(discographyProvider(artistId)),
      ),
    );
  }
}

class _ArtistBody extends ConsumerWidget {
  const _ArtistBody({required this.discography});
  final DiscographyModel discography;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = discography.artist;
    final grouped = discography.groupedByType;

    // Skladby z nejnovějšího vydání -- jen záloha, když k interpretovi
    // nejsou populární skladby (viz `_PopularTracksSection`).
    final sortedReleases = [...discography.releases]
      ..sort((a, b) => (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''));
    final topRelease = sortedReleases.isEmpty ? null : sortedReleases.first;
    final topTracks = topRelease == null ? null : ref.watch(releaseTracksProvider(topRelease.id));
    final bio = ref.watch(artistBioProvider(artist.id));
    final artistLater =
        ref.watch(listenLaterProvider.select((s) => s.valueOrNull?.find(LaterKind.artist, artist.id) != null));

    return ScreenAccent(
      imageUrl: artist.coverImageUrl,
      builder: (context, accent) => Scaffold(
        bottomNavigationBar: const PlayerBar(),
        body: CustomScrollView(
          slivers: [
            DetailHeroAppBar(
              title: artist.name,
              imageUrl: artist.coverImageUrl,
              accent: accent,
              eyebrow: 'Interpret',
              eyebrowIcon: Symbols.person_rounded,
              placeholderIcon: Symbols.person_rounded,
              bannerImageUrl: artist.bannerUrl,
              bannerFallbackUrl:
                  sortedReleases.map((r) => r.coverImageUrl).firstWhere((url) => url != null, orElse: () => null),
              // Pozadím je široký banner (nebo rozostřený obal) -- vlastní
              // portrét jako kulatý avatar vedle jména, ať je jasné, kdo to je.
              thumbnailUrl: artist.bannerUrl != null ? artist.coverImageUrl : null,
              thumbnailCircle: true,
              actions: [
                HeroAction(
                  icon: artistLater ? Symbols.event_busy_rounded : Symbols.schedule_rounded,
                  tooltip: artistLater ? 'Odebrat z Poslechnout později' : 'Prozkoumat později',
                  onPressed: () => ref.read(listenLaterProvider.notifier).toggle(context, LaterKind.artist, artist.id),
                ),
              ],
              meta: [
                if (grouped['album']?.length case final albums? when albums > 0)
                  HeroMetaItem(
                      Symbols.album_rounded,
                      '$albums ${albums == 1 ? 'album' : albums <= 4 ? 'alba' : 'alb'}'),
                HeroMetaItem(Symbols.library_music_rounded, '${discography.releases.length} vydání'),
                if (_activeYears(discography.releases) case final years?)
                  HeroMetaItem(Symbols.calendar_today_rounded, years),
              ],
            ),
            ...detailContentSlivers(context, [
              SliverToBoxAdapter(
                child: bio.maybeWhen(
                  data: (data) => data.bio == null ? const SizedBox.shrink() : HeroTeaser(text: data.bio!),
                  orElse: () => const SizedBox.shrink(),
                ),
              ),
              SliverToBoxAdapter(
                child: _PopularTracksSection(
                  artistId: artist.id,
                  artistName: artist.name,
                  fallback: topTracks == null
                      ? const SizedBox.shrink()
                      : topTracks.when(
                          data: (recordings) {
                            final top = recordings.take(5).toList();
                            if (top.isEmpty) return const SizedBox.shrink();
                            // Nejnovější vydání často nemá obal (čerstvý singl) --
                            // pak fotka interpreta, ne notová ikonka u všech řádků.
                            final rowArt = topRelease!.coverImageUrl ?? artist.coverImageUrl;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SectionHeader(
                                  'Z nejnovějšího vydání',
                                  onSeeAll: () => context.push('/releases/${topRelease.id}'),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      AppSpacing.md, AppSpacing.xxs, AppSpacing.md, AppSpacing.xs),
                                  child: QueueActionBar(
                                    tracks: top,
                                    sourceLabel: artist.name,
                                    artistName: artist.name,
                                    albumArtUrl: rowArt,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                                  child: Column(
                                    children: [
                                      for (final recording in top)
                                        TrackTile(
                                          recording: recording,
                                          queueRecordings: top,
                                          albumArtUrl: rowArt,
                                          artistName: artist.name,
                                          sourceLabel: artist.name,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                          loading: () => const Padding(
                            padding: EdgeInsets.only(top: AppSpacing.md),
                            child: SkeletonTrackList(count: 5),
                          ),
                          error: (_, __) => const SizedBox.shrink(),
                        ),
                ),
              ),
              SliverToBoxAdapter(
                child: bio.maybeWhen(
                  data: (data) => _RelatedArtistsSection(bio: data),
                  orElse: () => const SizedBox.shrink(),
                ),
              ),
              if (grouped.isEmpty)
                const SliverToBoxAdapter(
                  child: EmptyState(compact: true, message: 'Pro tohoto interpreta zatím nemáme žádná vydání.'),
                )
              else
                for (final entry in grouped.entries) ...[
                  SliverToBoxAdapter(
                    child: SectionHeader(
                      _releaseTypeLabels[entry.key] ?? entry.key,
                      // Celá diskografie jako časová osa (roky, chronologicky).
                      onSeeAll: () => context.push('/artists/${artist.id}/discography?type=${entry.key}'),
                    ),
                  ),
                  SliverToBoxAdapter(child: _ReleaseRail(releases: entry.value)),
                ],
              // Vrácené id (ne to z adresy) -- Deezer duplikát se na serveru
              // slučuje do kanonického interpreta s MBID.
              SliverToBoxAdapter(child: _RaritiesSection(artistId: artist.id)),
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
            ]),
          ],
        ),
      ),
    );
  }
}

final artistTopTracksProvider = FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getArtistTopTracks(artistId);
});

/// "8 691 poslechů" -- tisíce oddělené úzkou nezlomitelnou mezerou.
String _listensLabel(int count) {
  final digits = count.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  final word = count == 1
      ? 'poslech'
      : count >= 2 && count <= 4
          ? 'poslechy'
          : 'poslechů';
  return '$buffer $word';
}

/// "Populární" jako na Spotify/Apple Music -- nejposlouchanější skladby
/// s počty poslechů komunity ListenBrainz (bez MBID pořadí z Deezeru bez
/// počtů). Nic nenalezeno / chyba -> `fallback` (z nejnovějšího vydání).
class _PopularTracksSection extends ConsumerStatefulWidget {
  const _PopularTracksSection({required this.artistId, required this.artistName, required this.fallback});

  final String artistId;
  final String artistName;
  final Widget fallback;

  @override
  ConsumerState<_PopularTracksSection> createState() => _PopularTracksSectionState();
}

class _PopularTracksSectionState extends ConsumerState<_PopularTracksSection> {
  static const _collapsed = 5;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tracks = ref.watch(artistTopTracksProvider(widget.artistId));
    return tracks.when(
      data: (all) {
        if (all.isEmpty) return widget.fallback;
        final shown = _expanded ? all : all.take(_collapsed).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Populární'),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xxs, AppSpacing.md, AppSpacing.xs),
              child: QueueActionBar(tracks: all, sourceLabel: widget.artistName, artistName: widget.artistName),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Column(
                  children: [
                    for (final (i, recording) in shown.indexed)
                      TrackTile(
                        recording: recording,
                        leadingIndex: i + 1,
                        subtitle: recording.listenCount == null ? null : _listensLabel(recording.listenCount!),
                        queueRecordings: all,
                        artistName: widget.artistName,
                        sourceLabel: widget.artistName,
                      ),
                  ],
                ),
              ),
            ),
            if (all.length > _collapsed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: GlassButton(
                  label: _expanded ? 'Zobrazit méně' : 'Zobrazit víc',
                  style: GlassButtonStyle.plain,
                  compact: true,
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.only(top: AppSpacing.md),
        child: SkeletonTrackList(count: 5),
      ),
      error: (_, __) => widget.fallback,
    );
  }
}

/// "Podobní interpreti" (životopis je jako upoutávka hned pod hlavičkou).
class _RelatedArtistsSection extends StatelessWidget {
  const _RelatedArtistsSection({required this.bio});
  final ArtistBioModel bio;

  @override
  Widget build(BuildContext context) {
    final related = bio.relatedArtists;
    if (related.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...[
          const SectionHeader('Podobní interpreti'),
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              itemCount: related.length,
              itemBuilder: (context, index) {
                final a = related[index];
                return Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: SizedBox(
                    width: 130,
                    child: MediaCard(
                      title: a.name,
                      subtitle: 'Interpret',
                      shape: MediaCardShape.circle,
                      placeholderIcon: Symbols.person_rounded,
                      imageUrl: a.coverImageUrl,
                      artworkKey: (releaseId: null, artistId: a.id),
                      onTap: () => context.push('/artists/${a.id}'),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _ReleaseRail extends StatelessWidget {
  const _ReleaseRail({required this.releases});
  final List<ReleaseModel> releases;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 190,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        itemCount: releases.length,
        itemBuilder: (context, index) {
          final release = releases[index];
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: SizedBox(
              width: 140,
              child: MediaCard(
                title: release.title,
                subtitle: release.yearLabel,
                imageUrl: release.coverImageUrl,
                artworkKey: (releaseId: release.id, artistId: release.artistId),
                onTap: () => context.push('/releases/${release.id}'),
              ),
            ),
          );
        },
      ),
    );
  }
}

const _rarityLabels = {'demo': 'Dema', 'live': 'Živě', 'bootleg': 'Bootlegy'};
const _rarityBadges = {'demo': 'DEMO', 'live': 'ŽIVĚ', 'bootleg': 'BOOTLEG'};

/// "Nevydané a vzácné" pod oficiální diskografií -- dema, živé nahrávky a
/// bootlegy z MusicBrainz. Líně, se skeletonem; prázdné/nedostupné (503) se
/// vůbec neukáže.
class _RaritiesSection extends ConsumerStatefulWidget {
  const _RaritiesSection({required this.artistId});
  final String artistId;

  @override
  ConsumerState<_RaritiesSection> createState() => _RaritiesSectionState();
}

class _RaritiesSectionState extends ConsumerState<_RaritiesSection> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final rarities = ref.watch(artistRaritiesProvider(widget.artistId));
    return rarities.when(
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SectionHeader('Nevydané a vzácné'), SkeletonCardRail(height: 190)],
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        final kinds = [
          for (final k in _rarityLabels.keys)
            if (items.any((i) => i.rarity == k)) k
        ];
        final selected = kinds.contains(_selected) ? _selected! : kinds.first;
        final visible = items.where((i) => i.rarity == selected).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader('Nevydané a vzácné'),
            if (kinds.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                child: GlassSegmentedControl<String>(
                  segments: [
                    for (final k in kinds)
                      GlassSegment(
                          value: k, label: '${_rarityLabels[k]} · ${items.where((i) => i.rarity == k).length}'),
                  ],
                  selected: selected,
                  onChanged: (k) => setState(() => _selected = k),
                ),
              ),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final item = visible[index];
                  final release = item.release;
                  return Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: SizedBox(
                      width: 140,
                      child: Stack(
                        children: [
                          MediaCard(
                            title: release.title,
                            subtitle: release.yearLabel,
                            imageUrl: release.coverImageUrl,
                            artworkKey: (releaseId: release.id, artistId: release.artistId),
                            onTap: () => context.push('/releases/${release.id}'),
                          ),
                          Positioned(
                            left: AppSpacing.xs,
                            top: AppSpacing.xs,
                            child: RankBadge(label: _rarityBadges[item.rarity] ?? item.rarity.toUpperCase()),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
