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
import 'browse_grid.dart' show BrowseTile, categoryIcon;
import 'tag_screen.dart' show TagChips;
import '../../widgets/toast.dart';
import '../../widgets/collection_actions.dart';
import '../../core/cz_plural.dart';
import '../../data/home_repository.dart';
import '../../state/audio_player_controller.dart';
import '../../widgets/track_actions.dart' show nowPlayingInfoFor;

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
        toast(context, 'Playlist se nepodařilo otevřít, zkus to znovu.');
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
          leadingWidth: 16 + GlassBackButton.size,
          leading: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Align(alignment: Alignment.centerLeft, child: GlassBackButton(onPressed: () => context.pop())),
          ),
          flexibleSpace: FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(start: 72, bottom: 14),
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
                    child: Icon(categoryIcon(c), size: 110, color: Colors.white.withValues(alpha: 0.22)),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 1. Hlavní mix žánru (stejný jako na Domů) -- velká karta nahoře.
        if (data.mixes.isNotEmpty) SliverToBoxAdapter(child: _HeroMix(card: data.mixes.first, accent: c.color)),
        // Podžánry -- každý má vlastní stránku (mix, interpreti, alba).
        if (data.subgenres.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Podžánry')),
          SliverToBoxAdapter(child: _Subgenres(categoryId: c.id, subgenres: data.subgenres)),
        ],
        // 2. Pro tebe -- tvůj mix žánru, alba od tvých interpretů, koho ještě neznáš.
        SliverToBoxAdapter(child: _YourMix(categoryId: c.id)),
        if (c.group == 'genre') SliverToBoxAdapter(child: _ForYou(categoryId: c.id)),
        // 3. Novinky.
        if (data.mixes.length > 1 || data.newReleases.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Novinky')),
          SliverToBoxAdapter(
            child: _Rail(
              height: 214,
              children: [
                for (final m in data.mixes.skip(1))
                  PlaylistCardView(
                    card: m,
                    onTap: () => context.push('/playlists/${m.id}'),
                    onLongPress: () => showCollectionActions(
                      context,
                      kind: CollectionKind.playlist,
                      id: m.id,
                      title: m.title,
                      imageUrl: m.coverUrls.firstOrNull,
                    ),
                  ),
                for (final a in data.newReleases) SizedBox(width: 150, child: _albumCard(context, a)),
              ],
            ),
          ),
        ],
        // 4. Best of -- zásadní alba a nejposlouchanější skladby.
        if (data.classics.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Zásadní alba')),
          SliverToBoxAdapter(
            child: _Rail(
              height: 204,
              children: [for (final a in data.classics) SizedBox(width: 150, child: _albumCard(context, a))],
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
        // 5. Hlavní interpreti žánru.
        if ((data.topArtists.isEmpty ? data.artists : data.topArtists).isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Hlavní interpreti')),
          SliverToBoxAdapter(
            child: _Rail(
              height: 190,
              children: [
                for (final a in (data.topArtists.isEmpty ? data.artists : data.topArtists))
                  SizedBox(width: 130, child: _artistCard(context, a)),
              ],
            ),
          ),
        ],
        // Alba z žánrové řady (u nálad hlavní obsah, u žánrů doplněk).
        if (data.albums.isNotEmpty) ...[
          SliverToBoxAdapter(child: SectionHeader(c.group == 'genre' ? 'Další alba' : 'Alba')),
          SliverToBoxAdapter(
            child: _Rail(
              height: 204,
              children: [for (final a in data.albums) SizedBox(width: 150, child: _albumCard(context, a))],
            ),
          ),
        ],
        // 6. Playlisty z Deezeru.
        if (data.playlists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Playlisty')),
          SliverToBoxAdapter(
            child: _Rail(
              height: 214,
              children: [
                for (final p in data.playlists)
                  SizedBox(
                    width: 150,
                    child: _PlaylistTile(playlist: p, opening: _opening == p.deezerId, onTap: () => _openPlaylist(p)),
                  ),
              ],
            ),
          ),
        ],
        // 7. O žánru (Last.fm, anglicky) a podobné žánry.
        if (data.about != null) SliverToBoxAdapter(child: _About(text: data.about!, source: data.aboutSource)),
        if (data.related.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Podobné žánry')),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 168 / 1.75,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: data.related.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (_, i) => SizedBox(width: 168, child: BrowseTile(category: data.related[i])),
              ),
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
      duration: Motion.enter.duration,
      curve: Motion.enter,
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
        toast(context, 'Playlist se nepodařilo otevřít, zkus to znovu.');
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
              songsCount(playlist.trackCount!),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}


Widget _albumCard(BuildContext context, HomeAlbumCard a) => MediaCard(
      title: a.title,
      subtitle: a.artistName,
      imageUrl: a.images.isEmpty ? null : a.images.first,
      artworkKey: (releaseId: a.id, artistId: a.artistId),
      onTap: () => context.push('/releases/${a.id}'),
      onLongPress: () => showCollectionActions(
        context,
        kind: CollectionKind.album,
        id: a.id,
        title: a.title,
        subtitle: a.artistName,
        imageUrl: a.images.isEmpty ? null : a.images.first,
      ),
    );

Widget _artistCard(BuildContext context, BrowseArtist a) => MediaCard(
      title: a.name,
      imageUrl: a.images.isEmpty ? null : a.images.first,
      shape: MediaCardShape.circle,
      placeholderIcon: Symbols.person_rounded,
      artworkKey: (releaseId: null, artistId: a.id),
      onTap: () => context.push('/artists/${a.id}'),
    );

/// Hlavní mix žánru nahoře stránky: velký obal, název, popis a Přehrát.
class _HeroMix extends ConsumerStatefulWidget {
  const _HeroMix({required this.card, required this.accent});
  final HomePlaylistCard card;
  final Color accent;

  @override
  ConsumerState<_HeroMix> createState() => _HeroMixState();
}

class _HeroMixState extends ConsumerState<_HeroMix> {
  bool _loading = false;

  Future<void> _play() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final detail = await ref.read(playlistsRepositoryProvider).get(widget.card.id);
      final infos = [for (final t in detail.items) nowPlayingInfoFor(t)];
      if (infos.isNotEmpty) {
        await ref.read(audioPlayerControllerProvider.notifier).playQueue(infos, 0, sourceLabel: widget.card.title);
      }
    } catch (_) {
      if (mounted) {
        toast(context, 'Mix se nepodařilo spustit.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = widget.card;
    final shape = AppShapes.of(Expressive.cornerLarge);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: GlassPressable(
        shape: shape,
        minSize: Size.zero,
        onPressed: () => context.push('/playlists/${card.id}'),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 128,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: shape,
                  shadows: const [BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))],
                ),
                child: ClipPath(
                  clipper: ShapeBorderClipper(shape: shape),
                  child: card.coverUrls.isEmpty
                      ? ColoredBox(color: widget.accent)
                      : NetImage(url: card.coverUrls.first),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MIX ŽÁNRU', style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2, color: theme.colorScheme.primary)),
                  const SizedBox(height: 2),
                  Text(card.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
                  if (card.description != null)
                    Text(
                      card.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  const SizedBox(height: AppSpacing.xs),
                  GlassButton(
                    label: _loading ? 'Načítám…' : 'Přehrát',
                    icon: Symbols.play_arrow_rounded,
                    style: GlassButtonStyle.prominent,
                    compact: true,
                    onPressed: _loading ? null : _play,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pro tebe (podle tvých poslechů): alba žánru od interpretů, které
/// posloucháš, a hlavní interpreti žánru, které ještě neznáš.
class _ForYou extends ConsumerWidget {
  const _ForYou({required this.categoryId});
  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(browseForYouProvider(categoryId)).valueOrNull;
    if (data == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.albums.isNotEmpty) ...[
          const SectionHeader('Od tvých interpretů'),
          _Rail(
            height: 204,
            children: [for (final a in data.albums) SizedBox(width: 150, child: _albumCard(context, a))],
          ),
        ],
        if (data.discover.isNotEmpty) ...[
          const SectionHeader('Ještě neznáš'),
          _Rail(
            height: 190,
            children: [for (final a in data.discover) SizedBox(width: 130, child: _artistCard(context, a))],
          ),
        ],
      ],
    );
  }
}

/// O žánru -- krátký popis (Last.fm), rozbalitelný.
class _About extends StatefulWidget {
  const _About({required this.text, this.source});
  final String text;
  final String? source;

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('O žánru'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: Text(
                widget.text,
                maxLines: _open ? null : 4,
                overflow: _open ? null : TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
              ),
            ),
          ),
        ),
        if (widget.source != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 4, AppSpacing.md, 0),
            child: Text('Zdroj: ${widget.source}',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ),
      ],
    );
  }
}


/// Podžánry -- ty, které posloucháš, napřed a s hvězdičkou.
class _Subgenres extends ConsumerWidget {
  const _Subgenres({required this.categoryId, required this.subgenres});
  final String categoryId;
  final List<({String tag, String title})> subgenres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(browseForYouProvider(categoryId)).valueOrNull?.yourSubgenres.toSet() ?? const <String>{};
    final ordered = [
      ...subgenres.where((s) => mine.contains(s.tag)),
      ...subgenres.where((s) => !mine.contains(s.tag)),
    ];
    return TagChips(
      tags: [for (final s in ordered) s.tag],
      titles: [for (final s in ordered) mine.contains(s.tag) ? '★ ${s.title}' : s.title],
    );
  }
}
