import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/home_repository.dart';
import '../../models/recording_model.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/recently_played_pill.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';

/// Domů -- celá obrazovka z `GET /home` (žebříčky, mixy, nová a populární
/// alba, žánry, nálady), sekce se vykreslují podle `type`. Prázdné sekce
/// server vůbec nepošle.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return 'Dobrou noc';
    if (hour < 10) return 'Dobré ráno';
    if (hour < 18) return 'Dobrý den';
    return 'Dobrý večer';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    final recentlyPlayed = ref.watch(audioPlayerControllerProvider.select((s) => s.recentlyPlayed));

    return Scaffold(
      appBar: SectionAppBar(_greeting()),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(homeProvider);
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
                  message: 'Domů se zatím připravuje -- žebříčky a mixy se generují na pozadí, zkus to za pár minut.',
                ),
              for (final section in sections) ...[
                _HomeSectionView(section: section),
                // Naposledy přehrané hned pod rychlým výběrem.
                if (section.type == HomeSectionType.quickPicks && recentlyPlayed.length >= 3)
                  _RecentlyPlayed(recentlyPlayed: recentlyPlayed),
              ],
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

class _RecentlyPlayed extends StatelessWidget {
  const _RecentlyPlayed({required this.recentlyPlayed});
  final List<NowPlayingInfo> recentlyPlayed;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Naposledy přehráno'),
          SizedBox(
            height: 66,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              itemCount: recentlyPlayed.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: RecentlyPlayedPill(info: recentlyPlayed[index], queue: recentlyPlayed),
              ),
            ),
          ),
        ],
      );
}

class _HomeSectionView extends StatelessWidget {
  const _HomeSectionView({required this.section});
  final HomeSection section;

  @override
  Widget build(BuildContext context) {
    switch (section.type) {
      case HomeSectionType.quickPicks:
        return _QuickPicks(cards: section.playlists);
      case HomeSectionType.playlistCards:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.playlists.length > 3
                  ? () => _showPlaylistGrid(context, section.title, section.playlists)
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
                  return PlaylistCardView(card: card, onTap: () => context.push('/playlists/${card.id}'));
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
      animationIndex: index == null ? null : index % 8,
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
                  child: QuickPickTile(card: card, onTap: () => context.push('/playlists/${card.id}')),
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
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          itemCount: recordings.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
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
            const SkeletonBox(width: 140, height: 20),
            const SizedBox(height: AppSpacing.sm),
            const SkeletonCardRail(height: 190, cardWidth: 150),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      );
}
