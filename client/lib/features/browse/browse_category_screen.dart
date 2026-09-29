import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/browse_repository.dart';
import '../../state/providers.dart';
import '../../theme/accent_color.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/net_image.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';
import 'browse_grid.dart' show browseIcon;

/// Stránka jedné kategorie z Procházet: playlisty (redakční Deezer), u žánrů
/// i populární skladby, alba a interpreti. Barva kategorie tónuje appku.
class BrowseCategoryScreen extends ConsumerStatefulWidget {
  const BrowseCategoryScreen({super.key, required this.categoryId});
  final String categoryId;

  @override
  ConsumerState<BrowseCategoryScreen> createState() => _BrowseCategoryScreenState();
}

class _BrowseCategoryScreenState extends ConsumerState<BrowseCategoryScreen> {
  final Object _accentOwner = Object();
  late final ScreenAccentStack _accents = ref.read(screenAccentStackProvider.notifier);
  String? _opening;

  @override
  void dispose() {
    final accents = _accents;
    final owner = _accentOwner;
    WidgetsBinding.instance.addPostFrameCallback((_) => accents.remove(owner));
    super.dispose();
  }

  void _setAccent(Color color) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _accents.set(_accentOwner, color);
    });
  }

  Future<void> _openPlaylist(BrowsePlaylist p) async {
    if (_opening != null) return;
    setState(() => _opening = p.deezerId);
    try {
      final id = await ref.read(browseRepositoryProvider).openDeezerPlaylist(p.deezerId);
      if (mounted) context.push('/playlists/$id');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('Playlist se nepodařilo otevřít, zkus to znovu.')));
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(browsePageProvider(widget.categoryId));
    return Scaffold(
      bottomNavigationBar: const PlayerBar(),
      body: page.when(
        data: (data) {
          _setAccent(data.category.color);
          return _content(context, data);
        },
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Kategorii se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(browsePageProvider(widget.categoryId)),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, BrowsePage data) {
    final theme = Theme.of(context);
    final c = data.category;
    final top = MediaQuery.paddingOf(context).top;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 170 + top,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(icon: const Icon(Symbols.arrow_back_rounded), onPressed: () => context.pop()),
          flexibleSpace: FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14),
            title: Text(c.title, style: const TextStyle(fontWeight: FontWeight.w800)),
            background: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [c.color.withValues(alpha: 0.85), c.color.withValues(alpha: 0.0)],
                ),
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.lg),
                  child: Transform.rotate(
                    angle: 0.3,
                    child: Icon(browseIcon(c.icon), size: 110, color: Colors.white.withValues(alpha: 0.22)),
                  ),
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _YourMix(categoryId: c.id)),
        if (data.playlists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Playlisty')),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 190,
                childAspectRatio: 0.74,
                crossAxisSpacing: AppSpacing.sm,
                mainAxisSpacing: AppSpacing.sm,
              ),
              itemCount: data.playlists.length,
              itemBuilder: (context, i) => _PlaylistTile(
                playlist: data.playlists[i],
                opening: _opening == data.playlists[i].deezerId,
                onTap: () => _openPlaylist(data.playlists[i]),
              ),
            ),
          ),
        ],
        if (data.tracks.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Populární skladby')),
          SliverList.builder(
            itemCount: data.tracks.length.clamp(0, 10),
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: TrackTile(
                recording: data.tracks[i],
                queueRecordings: data.tracks,
                sourceLabel: c.title,
                leadingIndex: i + 1,
              ),
            ),
          ),
        ],
        if (data.albums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Alba')),
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
        if (data.artists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Interpreti')),
          SliverToBoxAdapter(
            child: _Rail(
              height: 190,
              children: [
                for (final a in data.artists)
                  SizedBox(
                    width: 130,
                    child: MediaCard(
                      title: a.name,
                      imageUrl: a.images.isEmpty ? null : a.images.first,
                      shape: MediaCardShape.circle,
                      placeholderIcon: Symbols.person_rounded,
                      onTap: () => context.push('/artists/${a.id}'),
                    ),
                  ),
              ],
            ),
          ),
        ],
        SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + MediaQuery.paddingOf(context).bottom)),
        if (data.playlists.isEmpty && data.tracks.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Text('Pro tuhle kategorii teď nic nemáme.', style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }
}

/// "Pro tebe": mix kategorie z tvých poslechů. Poprvé za den se skládá pár
/// sekund (načítá se zvlášť, stránka na něj nečeká); bez dost tvých skladeb
/// v kategorii se sekce vůbec neukáže.
class _YourMix extends ConsumerWidget {
  const _YourMix({required this.categoryId});
  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mix = ref.watch(browseMixProvider(categoryId));
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: mix.when(
        data: (card) => card == null
            ? const SizedBox(width: double.infinity)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader('Pro tebe'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: PlaylistCardView(
                      card: card,
                      width: 170,
                      onTap: () => context.push('/playlists/${card.id}'),
                    ),
                  ),
                ],
              ),
        loading: () => Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
          child: Row(
            children: [
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Skládám tvůj mix…',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        error: (_, __) => const SizedBox(width: double.infinity),
      ),
    );
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

/// Playlist z Deezeru, který se sám otevře: převezme ho do katalogu (chvíli
/// točí kolečko) a přejde na jeho stránku. Pro Hledat a další místa mimo
/// stránku kategorie.
class DeezerPlaylistTile extends ConsumerStatefulWidget {
  const DeezerPlaylistTile({super.key, required this.playlist});
  final BrowsePlaylist playlist;

  @override
  ConsumerState<DeezerPlaylistTile> createState() => _DeezerPlaylistTileState();
}

class _DeezerPlaylistTileState extends ConsumerState<DeezerPlaylistTile> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final id = await ref.read(browseRepositoryProvider).openDeezerPlaylist(widget.playlist.deezerId);
      if (mounted) context.push('/playlists/$id');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('Playlist se nepodařilo otevřít, zkus to znovu.')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => _PlaylistTile(playlist: widget.playlist, opening: _opening, onTap: _open);
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.playlist, required this.opening, required this.onTap});
  final BrowsePlaylist playlist;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = AppShapes.of(Expressive.cornerLarge);
    return GlassPressable(
      shape: shape,
      minSize: Size.zero,
      onPressed: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                shadows: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: ClipPath(
                clipper: ShapeBorderClipper(shape: shape),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (playlist.pictureUrl != null)
                      NetImage(url: playlist.pictureUrl!)
                    else
                      ColoredBox(color: theme.colorScheme.secondaryContainer),
                    if (opening)
                      const ColoredBox(
                        color: Color(0x66000000),
                        child: Center(child: ExpressiveLoadingIndicator(color: Colors.white)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(playlist.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
          if (playlist.trackCount != null)
            Text(
              '${playlist.trackCount} skladeb',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
