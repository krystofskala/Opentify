import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/artist_bio_model.dart';
import '../../models/discography_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/media_card.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/queue_action_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';
import '../release/release_screen.dart' show releaseTracksProvider;

final discographyProvider =
    FutureProvider.autoDispose.family<DiscographyModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getDiscography(artistId);
});

/// Životopis/podobní interpreti chodí z Wikidata/Wikipedie -- samostatně,
/// ať na ně nečeká tracklist/diskografie z lokální DB.
final artistBioProvider =
    FutureProvider.autoDispose.family<ArtistBioModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getArtistBio(artistId);
});

const _releaseTypeLabels = {
  'album': 'Alba',
  'ep': 'EP',
  'single': 'Singly',
  'compilation': 'Kompilace',
};

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

    // Žádný "top tracks" endpoint na backendu -- skladby z nejnovějšího
    // vydání, ať jde interpreta přehrát bez proklikávání přes album.
    final sortedReleases = [...discography.releases]
      ..sort((a, b) => (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''));
    final topRelease = sortedReleases.isEmpty ? null : sortedReleases.first;
    final topTracks = topRelease == null ? null : ref.watch(releaseTracksProvider(topRelease.id));
    final bio = ref.watch(artistBioProvider(artist.id));

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
              circleImage: true,
              placeholderIcon: Symbols.person_rounded,
              banner: true,
              expandedHeight: 320,
              bannerFallbackUrl: sortedReleases
                  .map((r) => r.coverImageUrl)
                  .firstWhere((url) => url != null, orElse: () => null),
              subtitle: [HeroMeta('${discography.releases.length} vydání')],
            ),
            if (topTracks != null)
              SliverToBoxAdapter(
                child: topTracks.when(
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
                          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xxs, AppSpacing.md, AppSpacing.xs),
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
            SliverToBoxAdapter(
              child: bio.maybeWhen(
                data: (data) => _ArtistBioSection(bio: data),
                orElse: () => const SizedBox.shrink(),
              ),
            ),
            if (grouped.isEmpty)
              const SliverToBoxAdapter(
                child: EmptyState(compact: true, message: 'Pro tohoto interpreta zatím nemáme žádná vydání.'),
              )
            else
              for (final entry in grouped.entries) ...[
                SliverToBoxAdapter(child: SectionHeader(_releaseTypeLabels[entry.key] ?? entry.key)),
                SliverToBoxAdapter(child: _ReleaseRail(releases: entry.value)),
              ],
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
          ],
        ),
      ),
    );
  }
}

/// Životopis (sbalený na pár řádků) + "Podobní interpreti".
class _ArtistBioSection extends StatefulWidget {
  const _ArtistBioSection({required this.bio});
  final ArtistBioModel bio;

  @override
  State<_ArtistBioSection> createState() => _ArtistBioSectionState();
}

class _ArtistBioSectionState extends State<_ArtistBioSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bioText = widget.bio.bio;
    final related = widget.bio.relatedArtists;
    if (bioText == null && related.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bioText != null) ...[
          const SectionHeader('O interpretovi'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bioText,
                  maxLines: _expanded ? null : 4,
                  overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
                  child: Text(_expanded ? 'Zobrazit méně' : 'Zobrazit více'),
                ),
              ],
            ),
          ),
        ],
        if (related.isNotEmpty) ...[
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
