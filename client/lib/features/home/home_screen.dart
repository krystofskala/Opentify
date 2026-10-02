import 'package:flutter/material.dart';
import '../../widgets/artist_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/listen_later_screen.dart' show ListenLaterReminder;
import 'package:material_symbols_icons/symbols.dart';

import '../../data/home_repository.dart';
import '../../models/recording_model.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/mix_artwork.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';
import '../../widgets/collection_actions.dart';
import '../blend/blend_screen.dart' show BlendInviteBanner;
import '../browse/browse_grid.dart' show BrowseTile;

/// Domů -- celá obrazovka z `GET /home` (žebříčky, mixy, nová a populární
/// alba, žánry, nálady), sekce se vykreslují podle `type`. Prázdné sekce
/// server vůbec nepošle.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  String _greeting() {
    final hour = DateTime.now().hour;
    // "Dobrou noc" se v češtině říká na rozloučenou, ne na pozdrav.
    if (hour < 5) return 'Dobrý večer';
    if (hour < 10) return 'Dobré ráno';
    if (hour < 18) return 'Dobrý den';
    return 'Dobrý večer';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    final recent = ref.watch(recentContextsProvider).valueOrNull ?? const <RecentContext>[];

    return Scaffold(
      appBar: SectionAppBar(_greeting()),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(homeProvider);
          ref.invalidate(recentContextsProvider);
          try {
            await ref.read(homeProvider.future);
          } catch (_) {}
        },
        child: home.when(
          data: (sections) => ListView(
            padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
            children: [
              if (sections.isEmpty)
                const EmptyState(
                  icon: Symbols.home_rounded,
                  message: 'Domů se zatím připravuje – žebříčky a mixy se generují na pozadí, zkus to za pár minut.',
                ),
              // Úplně nahoře: na co navázat (poslední poslouchaná alba).
              if (recent.isNotEmpty) _ContinueListening(items: recent),
              // Něco, co v "Poslechnout později" leží přes 2 týdny.
              // Pozvánka do společného mixu (Blend), čeká na mě.
              const BlendInviteBanner(),
              const ListenLaterReminder(),
              for (final section in sections) _HomeSectionView(section: section),
            ],
          ),
          loading: () => const _HomeSkeleton(),
          error: (error, stack) => ListView(
            children: [
              ErrorState(
                message: 'Domů se nepodařilo načíst.',
                error: error,
                onRetry: () => ref.invalidate(homeProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Pokračovat v poslechu" -- mřížka kompaktních dlaždic (obal + název +
/// interpret) jako Spotify nahoře na Domů. Ze serveru (`/home/recent`),
/// takže přežije obnovení stránky i jiné zařízení.
class _ContinueListening extends StatelessWidget {
  const _ContinueListening({required this.items});
  final List<RecentContext> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Pokračovat v poslechu'),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gap = AppSpacing.xs;
              // Stejné sloupce jako Rychlý výběr pod tím -- okraje dlaždic
              // pod sebou lícují (design audit #8).
              final columns = constraints.maxWidth >= 720 ? 3 : 2;
              final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
              final shape = AppShapes.of(Expressive.cornerMedium);
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final item in items.take(6))
                    SizedBox(
                      width: width,
                      height: 56,
                      child: GlassPressable(
                        shape: shape,
                        minSize: Size.zero,
                        // Dlouhý stisk: přehrát jako další / do fronty (alba a playlisty).
                        onLongPress: switch (item.kind) {
                          'album' => () => showCollectionActions(context,
                              kind: CollectionKind.album,
                              id: item.id,
                              title: item.title,
                              subtitle: item.artistName,
                              imageUrl: item.imageUrl),
                          'playlist' => () => showCollectionActions(context,
                              kind: CollectionKind.playlist,
                              id: item.id,
                              title: item.title,
                              imageUrl: item.imageUrls.firstOrNull),
                          'liked' => () => showCollectionActions(context,
                              kind: CollectionKind.liked, id: item.id, title: item.title),
                          'artist' => () =>
                              showArtistActions(context, id: item.id, name: item.title, imageUrl: item.imageUrl),
                          _ => null,
                        },
                        onPressed: () => switch (item.kind) {
                          'album' => context.push('/releases/${item.id}'),
                          'playlist' => context.push('/playlists/${item.id}'),
                          'liked' => context.push('/library/liked'),
                          'artist' => context.push('/artists/${item.id}'),
                          _ => item.artistId != null ? context.push('/artists/${item.artistId}') : null,
                        },
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            shape: shape,
                            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.72),
                          ),
                          child: ClipPath(
                            clipper: ShapeBorderClipper(shape: shape),
                            child: Row(
                              children: [
                                SizedBox(width: 56, height: 56, child: _recentArtwork(context, item)),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelLarge?.copyWith(
                                          color: theme.colorScheme.onSecondaryContainer,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (item.artistName != null)
                                        Text(
                                          item.artistName!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.75),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

Widget _recentArtwork(BuildContext context, RecentContext item) {
  switch (item.kind) {
    case 'playlist':
      // Vlastní mixy stejným generativním obalem jako na kartě a v
      // hlavičce -- dřív tu byla mozaika fotek (design audit #1).
      return PlaylistArtwork(
        title: item.title,
        coverUrls: item.imageUrls,
        showTitle: false,
        dailyMixNumber: item.dailyMixNumber,
        mix: mixArtForSource(
          source: item.source,
          title: item.title,
          photos: item.imageUrls,
          color: mixHex(item.accentColor),
          categoryGroup: item.artStyle == 'mood' ? 'mood' : null,
        ),
      );
    case 'liked':
      final scheme = Theme.of(context).colorScheme;
      return ColoredBox(
        color: scheme.primaryContainer,
        child: Icon(Symbols.favorite_rounded, fill: 1, color: scheme.onPrimaryContainer),
      );
    case 'artist':
      return Padding(
        padding: const EdgeInsets.all(4),
        child: ClipOval(child: ArtworkImage(url: item.imageUrl, icon: Symbols.person_rounded)),
      );
    default:
      return ArtworkImage(url: item.imageUrl, icon: Symbols.album_rounded);
  }
}

class _HomeSectionView extends StatelessWidget {
  const _HomeSectionView({required this.section});
  final HomeSection section;

  @override
  Widget build(BuildContext context) {
    switch (section.type) {
      case HomeSectionType.quickPicks:
        // Vlastní nadpis -- bez něj splýval s "Pokračovat v poslechu" nad ním
        // (stejné kompaktní dlaždice, živě nahlášeno).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [SectionHeader(section.title), _QuickPicks(cards: section.playlists)],
        );
      case HomeSectionType.playlistCards:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.playlists.length > 3
                  ? () => _showPlaylistGrid(context, section.title, section.playlists)
                  : null,
              // "Tvoje roky" -> Wrapped (statistiky a sdílecí obrázky).
              trailing: section.id == 'years'
                  ? TextButton.icon(
                      onPressed: () => context.push('/wrapped'),
                      icon: const Icon(Symbols.equalizer_rounded, size: 18),
                      label: const Text('Wrapped'),
                    )
                  : null,
            ),
            SizedBox(
              height: 214,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.playlists.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final card = section.playlists[index];
                  return PlaylistCardView(
                    card: card,
                    onTap: () => context.push('/playlists/${card.id}'),
                    onLongPress: () => _playlistActions(context, card),
                  );
                },
              ),
            ),
          ],
        );
      case HomeSectionType.albumCards:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.albums.length > 3 ? () => _showAlbumGrid(context, section.title, section.albums) : null,
            ),
            SizedBox(
              height: 204,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.albums.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) =>
                    SizedBox(width: 150, child: _albumCard(context, section.albums[index], index)),
              ),
            ),
          ],
        );
      case HomeSectionType.trackRail:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.playlistId != null ? () => context.push('/playlists/${section.playlistId}') : null,
            ),
            _TrackCardRow(recordings: section.tracks, sourceLabel: section.title),
          ],
        );
      case HomeSectionType.categoryTiles:
        // Stejné dlaždice jako v Hledat (BrowseTile), ne karty playlistů.
        const tileWidth = 168.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: () => _showGrid(
                context,
                section.title,
                section.categories.length,
                (context, index) => BrowseTile(category: section.categories[index]),
                1.75,
              ),
            ),
            SizedBox(
              height: tileWidth / 1.75,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) =>
                    SizedBox(width: tileWidth, child: BrowseTile(category: section.categories[index])),
              ),
            ),
          ],
        );
      case HomeSectionType.unknown:
        return const SizedBox.shrink();
    }
  }
}

Widget _albumCard(BuildContext context, HomeAlbumCard album, int? index) => MediaCard(
      title: album.title,
      subtitle: album.artistName,
      imageUrl: album.images.isEmpty ? null : album.images.first,
      artworkKey: (releaseId: album.id, artistId: album.artistId),
      onTap: () => context.push('/releases/${album.id}'),
      onLongPress: () => showCollectionActions(
        context,
        kind: CollectionKind.album,
        id: album.id,
        title: album.title,
        subtitle: album.artistName,
        imageUrl: album.images.isEmpty ? null : album.images.first,
      ),
      animationIndex: index == null ? null : index % 8,
    );

void _playlistActions(BuildContext context, HomePlaylistCard card) => showCollectionActions(
      context,
      kind: CollectionKind.playlist,
      id: card.id,
      title: card.title,
      subtitle: card.description,
      imageUrl: card.coverUrls.firstOrNull,
    );

/// Rychlý výběr -- 2 sloupce kompaktních dlaždic.
class _QuickPicks extends StatelessWidget {
  const _QuickPicks({required this.cards});
  final List<HomePlaylistCard> cards;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = AppSpacing.xs;
          final columns = constraints.maxWidth >= 720 ? 3 : 2;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final card in cards)
                SizedBox(
                  width: width,
                  height: 56,
                  child: QuickPickTile(
                    card: card,
                    onTap: () => context.push('/playlists/${card.id}'),
                    onLongPress: () => _playlistActions(context, card),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TrackCardRow extends StatelessWidget {
  const _TrackCardRow({required this.recordings, required this.sourceLabel});
  final List<RecordingModel> recordings;
  final String sourceLabel;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 198,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          // Jako nadpisy sekcí (md) -- první karta dřív seděla 4 px vlevo.
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          itemCount: recordings.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, index) => Padding(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 140,
              child: TrackTile(
                layout: TrackTileLayout.card,
                recording: recordings[index],
                queueRecordings: recordings,
                sourceLabel: sourceLabel,
                animationIndex: index,
              ),
            ),
          ),
        ),
      );
}

/// "Zobrazit vše" -- mřížka ve skleněném sheetu (překryv = sklo).
Future<void> _showGrid(
    BuildContext context, String title, int count, Widget Function(BuildContext, int) itemBuilder, double aspect) {
  return showGlassSheet(
    context,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => GlassSheet(
        expand: true,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
                child: Text(title, style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  childAspectRatio: aspect,
                  crossAxisSpacing: AppSpacing.sm,
                  mainAxisSpacing: AppSpacing.sm,
                ),
                itemCount: count,
                itemBuilder: itemBuilder,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showPlaylistGrid(BuildContext context, String title, List<HomePlaylistCard> cards) => _showGrid(
      context,
      title,
      cards.length,
      (context, index) => LayoutBuilder(
        builder: (context, c) => PlaylistCardView(
          card: cards[index],
          width: c.maxWidth,
          onTap: () {
            Navigator.of(context).pop();
            context.push('/playlists/${cards[index].id}');
          },
        ),
      ),
      0.72,
    );

Future<void> _showAlbumGrid(BuildContext context, String title, List<HomeAlbumCard> albums) => _showGrid(
      context,
      title,
      albums.length,
      (context, index) => MediaCard(
        title: albums[index].title,
        subtitle: albums[index].artistName,
        imageUrl: albums[index].images.isEmpty ? null : albums[index].images.first,
        onTap: () {
          Navigator.of(context).pop();
          context.push('/releases/${albums[index].id}');
        },
      ),
      0.74,
    );

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (var i = 0; i < 6; i++)
                LayoutBuilder(
                  builder: (context, _) => SkeletonBox(
                    width: (MediaQuery.sizeOf(context).width - AppSpacing.md * 2 - AppSpacing.xs) / 2,
                    height: 56,
                    radius: AppRadii.md,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          for (var i = 0; i < 3; i++) ...[
            // Align: v ListView by se box roztáhl přes celou šířku.
            const Align(alignment: Alignment.centerLeft, child: SkeletonBox(width: 140, height: 20)),
            const SizedBox(height: AppSpacing.sm),
            const SkeletonCardRail(height: 190, cardWidth: 150),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      );
}
