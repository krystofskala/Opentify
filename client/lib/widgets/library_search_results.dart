import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/library_repository.dart';
import '../state/providers.dart';
import '../theme/design_tokens.dart';
import 'media_card.dart';
import 'state_views.dart';
import 'track_tile.dart';
import '../routing/home_shell.dart' show navBottomInset;
import '../core/cz_plural.dart';

const _librarySourceLabel = 'Hledání v knihovně';

/// `GET /library/search` -- jen obsah knihovny, bez diakritiky.
final librarySearchProvider = FutureProvider.autoDispose.family<LibrarySearchResult, String>((ref, query) {
  return ref.watch(libraryRepositoryProvider).searchLibrary(query, limit: 40);
});

/// Které části výsledku ukázat -- `all` = seskupené sekce, ostatní = jen
/// jeden typ přes celou plochu (stejně jako filtrovací čipy v Hledání).
enum LibrarySearchScope { all, tracks, artists, albums }

/// Výsledky hledání v knihovně -- sdílené Knihovnou i režimem "Jen moje
/// knihovna" v globálním Hledání, ať obě místa vypadají a chovají se stejně
/// jako výsledky z katalogu (stejné sekce, `TrackTile`, `MediaCard`).
class LibrarySearchResults extends ConsumerWidget {
  const LibrarySearchResults({
    super.key,
    required this.query,
    this.scope = LibrarySearchScope.all,
    this.onSeeAll,
  });

  final String query;
  final LibrarySearchScope scope;

  /// "Zobrazit vše" u sekce -- volající přepne `scope` (čip). `null` = bez odkazu.
  final ValueChanged<LibrarySearchScope>? onSeeAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(librarySearchProvider(query));
    return result.when(
      loading: () => scope == LibrarySearchScope.all || scope == LibrarySearchScope.tracks
          ? const SkeletonTrackList(count: 6)
          : const LoadingState(count: 6),
      error: (error, stack) => ErrorState(
        message: 'Hledání v knihovně selhalo.',
        error: error,
        onRetry: () => ref.invalidate(librarySearchProvider(query)),
      ),
      data: (data) {
        if (data.isEmpty) {
          return EmptyState(icon: Symbols.search_off_rounded, message: 'V knihovně pro „$query“ nic není.');
        }
        return switch (scope) {
          LibrarySearchScope.all => _grouped(context, data),
          LibrarySearchScope.tracks => _trackList(context, data),
          LibrarySearchScope.artists => _grid(context, [for (final a in data.artists) _artistCard(context, a)],
              aspect: 0.8, emptyLabel: 'Žádní interpreti'),
          LibrarySearchScope.albums => _grid(context, [for (final a in data.albums) _albumCard(context, a)],
              aspect: 0.72, emptyLabel: 'Žádná alba'),
        };
      },
    );
  }

  Widget _grouped(BuildContext context, LibrarySearchResult data) {
    VoidCallback? seeAll(LibrarySearchScope s) => onSeeAll == null ? null : () => onSeeAll!(s);
    return ListView(
      padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
      children: [
        if (data.tracks.isNotEmpty) ...[
          SectionHeader('Skladby', onSeeAll: data.tracks.length > 5 ? seeAll(LibrarySearchScope.tracks) : null),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Column(
              children: [
                for (final r in data.tracks.take(5))
                  TrackTile(recording: r, queueRecordings: data.tracks, sourceLabel: _librarySourceLabel),
              ],
            ),
          ),
        ],
        if (data.artists.isNotEmpty) ...[
          SectionHeader('Interpreti', onSeeAll: seeAll(LibrarySearchScope.artists)),
          _Rail(height: 180, children: [for (final a in data.artists) _artistCard(context, a)]),
        ],
        if (data.albums.isNotEmpty) ...[
          SectionHeader('Alba', onSeeAll: seeAll(LibrarySearchScope.albums)),
          _Rail(height: 190, width: 140, children: [for (final a in data.albums) _albumCard(context, a)]),
        ],
        if (data.playlists.isNotEmpty) ...[
          const SectionHeader('Playlisty'),
          _Rail(
            height: 190,
            width: 140,
            children: [
              for (final p in data.playlists)
                MediaCard(
                  title: p.title,
                  subtitle: songsCount(p.itemCount),
                  placeholderIcon: Symbols.queue_music_rounded,
                  onTap: () => context.push('/playlists/${p.id}'),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _trackList(BuildContext context, LibrarySearchResult data) {
    if (data.tracks.isEmpty) {
      return EmptyState(icon: Symbols.search_off_rounded, message: 'Žádné skladby pro „$query“ v knihovně.');
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.lg + navBottomInset(context)),
      itemCount: data.tracks.length,
      itemBuilder: (context, index) => TrackTile(
        recording: data.tracks[index],
        queueRecordings: data.tracks,
        sourceLabel: _librarySourceLabel,
      ),
    );
  }

  Widget _grid(BuildContext context, List<Widget> cards, {required double aspect, required String emptyLabel}) {
    if (cards.isEmpty) {
      return EmptyState(icon: Symbols.search_off_rounded, message: '$emptyLabel pro „$query“ v knihovně.');
    }
    final columns = (MediaQuery.sizeOf(context).width / 170).floor().clamp(2, 8);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm + navBottomInset(context)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: aspect,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
      ),
      itemCount: cards.length,
      itemBuilder: (context, index) => cards[index],
    );
  }

  Widget _artistCard(BuildContext context, LocalArtist a) => MediaCard(
        shape: MediaCardShape.circle,
        placeholderIcon: Symbols.person_rounded,
        title: a.name,
        subtitle: songsCount(a.trackCount),
        imageUrl: a.imageUrl,
        artworkKey: (releaseId: null, artistId: a.id),
        onTap: () => context.push('/artists/${a.id}'),
      );

  Widget _albumCard(BuildContext context, LocalAlbum a) => MediaCard(
        title: a.title,
        subtitle: a.artistName,
        imageUrl: a.coverImageUrl,
        artworkKey: (releaseId: a.id, artistId: a.artistId),
        onTap: () => context.push('/releases/${a.id}'),
      );
}

class _Rail extends StatelessWidget {
  const _Rail({required this.height, required this.children, this.width = 130});

  final double height;
  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          itemCount: children.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: SizedBox(width: width, child: children[index]),
          ),
        ),
      );
}
