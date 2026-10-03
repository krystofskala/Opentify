import '../../routing/branches.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/browse_repository.dart';
import '../../data/home_repository.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/collection_actions.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/state_views.dart';
import 'browse_category_screen.dart' show DeezerPlaylistTile;
import 'browse_grid.dart' show BrowseTile;

/// Odkaz na stránku stylu (podžánr / štítek interpreta).
String tagRoute(String tag) => '/browse/tag/${Uri.encodeComponent(tag)}';

/// Stránka stylu ze štítku Last.fm (`GET /browse/tag/{tag}`).
class TagPage {
  const TagPage({
    required this.tag,
    required this.title,
    this.mix,
    this.forYou,
    this.playlists = const [],
    this.topArtists = const [],
    this.albums = const [],
    this.about,
    this.parents = const [],
    this.related = const [],
  });

  final String tag;
  final String title;
  final HomePlaylistCard? mix;
  /// "Pro tebe · X" -- podle tvého poslechu (null, když styl skoro neposloucháš).
  final HomePlaylistCard? forYou;
  /// Populární playlisty stylu z Deezeru.
  final List<BrowsePlaylist> playlists;
  final List<BrowseArtist> topArtists;
  final List<HomeAlbumCard> albums;
  final String? about;
  final List<BrowseCategory> parents;
  final List<String> related;

  TagPage copyWithExtras({HomePlaylistCard? mix, HomePlaylistCard? forYou, List<BrowsePlaylist>? playlists}) => TagPage(
        tag: tag,
        title: title,
        mix: mix ?? this.mix,
        forYou: forYou ?? this.forYou,
        playlists: playlists ?? this.playlists,
        topArtists: topArtists,
        albums: albums,
        about: about,
        parents: parents,
        related: related,
      );

  factory TagPage.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> list(String key) =>
        (json[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    return TagPage(
      tag: json['tag'] as String,
      title: json['title'] as String,
      mix: json['mix'] == null ? null : HomePlaylistCard.fromJson(json['mix'] as Map<String, dynamic>),
      forYou: json['forYou'] == null ? null : HomePlaylistCard.fromJson(json['forYou'] as Map<String, dynamic>),
      playlists: list('playlists').map(BrowsePlaylist.fromJson).toList(),
      topArtists: list('topArtists').map(BrowseArtist.fromJson).toList(),
      albums: list('albums').map(HomeAlbumCard.fromJson).toList(),
      about: json['about'] as String?,
      parents: list('parents').map(BrowseCategory.fromJson).toList(),
      related: (json['related'] as List<dynamic>? ?? const []).cast<String>(),
    );
  }
}

final tagPageProvider = FutureProvider.autoDispose.family<TagPage, String>((ref, tag) async {
  final json = await ref.watch(apiClientProvider).getJson('/browse/tag/${Uri.encodeComponent(tag)}');
  return TagPage.fromJson(json);
});

/// Mix stylu "X · nejoblíbenější" zvlášť -- skládá se nejdéle.
final tagMixProvider = FutureProvider.autoDispose.family<HomePlaylistCard?, String>((ref, tag) async {
  final json = await ref.watch(apiClientProvider).getJson('/browse/tag-mix/${Uri.encodeComponent(tag)}');
  final card = json['mix'];
  return card == null ? null : HomePlaylistCard.fromJson(card as Map<String, dynamic>);
});

/// "Pro tebe · X" zvlášť -- skládá se déle, stránka na něj nečeká.
final tagForYouProvider = FutureProvider.autoDispose.family<HomePlaylistCard?, String>((ref, tag) async {
  final json = await ref.watch(apiClientProvider).getJson('/browse/tag-for-you/${Uri.encodeComponent(tag)}');
  final card = json['forYou'];
  return card == null ? null : HomePlaylistCard.fromJson(card as Map<String, dynamic>);
});

/// Populární playlisty stylu z Deezeru zvlášť (první načtení trvá).
final tagPlaylistsProvider = FutureProvider.autoDispose.family<List<BrowsePlaylist>, String>((ref, tag) async {
  final json = await ref.watch(apiClientProvider).getJson('/browse/tag-playlists/${Uri.encodeComponent(tag)}');
  return (json['playlists'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>()
      .map(BrowsePlaylist.fromJson)
      .toList();
});

/// Řada čipů se styly (podžánry na stránce žánru, štítky interpreta).
class TagChips extends StatelessWidget {
  const TagChips({super.key, required this.tags, this.titles});
  final List<String> tags;

  /// Zobrazované názvy (jinak štítek).
  final List<String>? titles;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: tags.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.xs),
        itemBuilder: (context, i) => ActionChip(
          label: Text(titles?[i] ?? tags[i]),
          onPressed: () => context.push(tagRoute(tags[i])),
        ),
      ),
    );
  }
}

class TagScreen extends ConsumerWidget {
  const TagScreen({super.key, required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(tagPageProvider(tag));
    final theme = Theme.of(context);
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            leadingWidth: 16 + GlassBackButton.size,
            leading: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Align(alignment: Alignment.centerLeft, child: GlassBackButton(onPressed: () => context.pop())),
            ),
            title: Text(page.valueOrNull?.title ?? tag, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          ...page.when(
            data: (data) => _content(context, ref, data),
            loading: () => [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Skládám mix a výběr stylu… poprvé to může chvíli trvat.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SkeletonCardRail(height: 214, cardWidth: 150)),
            ],
            error: (e, _) => [
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorState(
                  message: 'Styl se nepodařilo načíst.',
                  error: e,
                  onRetry: () => ref.invalidate(tagPageProvider(tag)),
                ),
              ),
            ],
          ),
          SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + MediaQuery.paddingOf(context).bottom)),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context, WidgetRef ref, TagPage page) {
    final theme = Theme.of(context);
    // Osobní mix a playlisty dorazí zvlášť, až budou hotové.
    final data = page.copyWithExtras(
      mix: page.mix ?? ref.watch(tagMixProvider(tag)).valueOrNull,
      forYou: page.forYou ?? ref.watch(tagForYouProvider(tag)).valueOrNull,
      playlists: page.playlists.isNotEmpty ? page.playlists : ref.watch(tagPlaylistsProvider(tag)).valueOrNull,
    );
    return [
      if (data.forYou != null || data.mix != null) ...[
        const SliverToBoxAdapter(child: SectionHeader('Mixy')),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 214,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              children: [
                for (final card in [data.forYou, data.mix].whereType<HomePlaylistCard>())
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: PlaylistCardView(
                      card: card,
                      width: 170,
                      onTap: () => context.push('/playlists/${card.id}'),
                      onLongPress: () => showCollectionActions(
                        context,
                        kind: CollectionKind.playlist,
                        id: card.id,
                        title: card.title,
                        imageUrl: card.coverUrls.firstOrNull,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      if (data.playlists.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Populární playlisty')),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: data.playlists.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, i) => SizedBox(width: 150, child: DeezerPlaylistTile(playlist: data.playlists[i])),
            ),
          ),
        ),
      ],
      if (data.topArtists.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Hlavní interpreti')),
        SliverToBoxAdapter(
          child: _Rail(
            height: 190,
            children: [
              for (final a in data.topArtists)
                SizedBox(
                  width: 130,
                  child: MediaCard(
                    title: a.name,
                    imageUrl: a.images.isEmpty ? null : a.images.first,
                    shape: MediaCardShape.circle,
                    placeholderIcon: Symbols.person_rounded,
                    artworkKey: (releaseId: null, artistId: a.id),
                    onTap: () => context.push('/artists/${a.id}'),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (data.albums.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Zásadní alba')),
        SliverToBoxAdapter(
          child: _Rail(
            height: 204,
            children: [
              for (final a in data.albums)
                SizedBox(
                  width: 150,
                  child: MediaCard(
                    title: a.title,
                    subtitle: a.artistName,
                    imageUrl: a.images.isEmpty ? null : a.images.first,
                    artworkKey: (releaseId: a.id, artistId: a.artistId),
                    onTap: () => context.push('/releases/${a.id}'),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (data.related.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Příbuzné styly')),
        SliverToBoxAdapter(child: TagChips(tags: data.related)),
      ],
      if (data.parents.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Patří pod')),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 168 / 1.75,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: data.parents.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
              itemBuilder: (_, i) => SizedBox(width: 168, child: BrowseTile(category: data.parents[i])),
            ),
          ),
        ),
      ],
      if (data.about != null) ...[
        const SliverToBoxAdapter(child: SectionHeader('O stylu')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              data.about!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
            ),
          ),
        ),
      ],
      if (data.mix == null && data.forYou == null && data.playlists.isEmpty && data.topArtists.isEmpty && data.albums.isEmpty)
        const SliverToBoxAdapter(
          child: EmptyState(compact: true, message: 'K tomuhle stylu teď nic nemáme.'),
        ),
    ];
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.height, required this.children});
  final double height;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          itemCount: children.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (_, i) => children[i],
        ),
      );
}
