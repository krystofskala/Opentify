import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'shared_playlists_screen.dart';
import '../../data/playlists_repository.dart' show PlaylistSummaryModel;
import '../../models/recording_model.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/shapes.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/library_search_results.dart';
import '../../widgets/media_card.dart';
import '../../widgets/playlist_card.dart' show PlaylistArtwork;
import 'liked_songs_screen.dart' show LikedSongsCard;
import 'listen_later_screen.dart' show ListenLaterCard;
import '../../widgets/remove_from_library.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';
import '../../widgets/view_mode_toggle.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../widgets/collection_actions.dart';
import '../../core/cz_plural.dart';
import '../../state/auth_controller.dart';
import '../../state/library_scope.dart';
import 'offline_tab.dart';

const _pageSize = 100;
const _fullLoadPageSize = 500;
const _librarySourceLabel = 'Knihovna';

// `libraryRevisionProvider` -- po "Odebrat z knihovny" se přenačtou samy.
final _localAlbumsProvider = FutureProvider.autoDispose((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryRepositoryProvider).localAlbums();
});
final _localArtistsProvider = FutureProvider.autoDispose((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryRepositoryProvider).localArtists();
});

/// Knihovna -- všechno, co je na disku k okamžitému přehrání, v pilulkových
/// tabech Skladby/Alba/Interpreti/Playlisty (PixelPlayer styl). Karty
/// alb/interpretů vedou na sdílené Album/Interpret obrazovky.
class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

/// Hledání přes CELOU knihovnu (backend `GET /library/search`, bez
/// diakritiky) -- ne jen přes právě načtenou stránku skladeb. Během hledání
/// taby nahradí čipy rozsahu a obsah seskupené výsledky, stejné jako v Hledání.
class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  LibrarySearchScope _scope = LibrarySearchScope.all;

  static const _scopeLabels = {
    LibrarySearchScope.all: 'Vše',
    LibrarySearchScope.tracks: 'Skladby',
    LibrarySearchScope.artists: 'Interpreti',
    LibrarySearchScope.albums: 'Alba',
  };

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {}); // tlačítko vymazat
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        if (_query.isEmpty) _scope = LibrarySearchScope.all;
      });
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _scope = LibrarySearchScope.all;
    });
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.isNotEmpty;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: SectionAppBar(
          'Knihovna',
          // Admin: celá sdílená knihovna na serveru, nebo jen ta jeho.
          actions: const [_LibraryScopeToggle()],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(64 + 48),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                  child: GlassSearchField(
                    controller: _controller,
                    hintText: 'Hledat v knihovně…',
                    onChanged: _onChanged,
                    onCleared: _clear,
                  ),
                ),
                SizedBox(
                  height: 48,
                  // Segmentový ovladač místo čipů/Material tabů (HIG Segmented
                  // controls: přepínání příbuzných pohledů, ≤5 segmentů).
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: searching
                        ? GlassSegmentedControl<LibrarySearchScope>(
                            segments: [
                              for (final s in LibrarySearchScope.values)
                                GlassSegment(value: s, label: _scopeLabels[s]!),
                            ],
                            selected: _scope,
                            onChanged: (s) => setState(() => _scope = s),
                          )
                        : const _LibraryTabSegments(),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Taby zůstávají ve stromu (Offstage) i během hledání -- jinak by se
        // po vymazání dotazu znovu načítala celá knihovna a ztratil se scroll.
        body: Stack(
          children: [
            Offstage(
              offstage: searching,
              child: const TabBarView(
                children: [_SongsTab(), _AlbumsTab(), _ArtistsTab(), _PlaylistsTab(), OfflineTab()],
              ),
            ),
            if (searching)
              LibrarySearchResults(
                key: ValueKey('$_scope-$_query'),
                query: _query,
                scope: _scope,
                onSeeAll: (scope) => setState(() => _scope = scope),
              ),
          ],
        ),
      ),
    );
  }
}

/// Kolik sloupců mřížky se vejde vedle sebe (mobil 2-3, desktop klidně 6+).
int _gridColumns(double width) => (width / 170).floor().clamp(2, 8);

class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab();

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<_SongsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final List<RecordingModel> _items = [];
  final _collection = TrackCollectionController();
  int _total = 0;
  bool _loading = false;
  bool _initialLoadDone = false;
  Object? _error;
  ViewMode _viewMode = ViewMode.list;

  @override
  void initState() {
    super.initState();
    _collection.addListener(_onCollectionChanged);
    _loadMore();
  }

  @override
  void dispose() {
    _collection.removeListener(_onCollectionChanged);
    _collection.dispose();
    super.dispose();
  }

  // Filtr/řazení nad jen první načtenou stránkou by lhal ("nic nenalezeno",
  // i když skladba v knihovně je) -- jakmile je aktivní, dotáhne se zbytek.
  void _onCollectionChanged() {
    if (_collection.isModified && _items.length < _total) _loadAll();
  }

  Future<void> _loadMore({int pageSize = _pageSize}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final page = await ref.read(libraryRepositoryProvider).localTracks(limit: pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _initialLoadDone = true;
        });
      }
    }
  }

  Future<void> _loadAll() async {
    while (mounted && _items.length < _total && _error == null) {
      final before = _items.length;
      await _loadMore(pageSize: _fullLoadPageSize);
      if (_items.length == before) break;
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _initialLoadDone = false;
      _error = null;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(libraryRevisionProvider, (_, __) {
      _collection.setSelecting(false);
      _refresh();
    });
    if (!_initialLoadDone) return const LoadingState();
    if (_error != null && _items.isEmpty) {
      return ErrorState(message: 'Knihovnu se nepodařilo načíst.', error: _error, onRetry: _refresh);
    }
    if (_items.isEmpty) {
      return const EmptyState(
        icon: Symbols.library_music_rounded,
        message: 'Zatím žádné skladby – spusť sken v Profilu, nebo si nějakou přehraj '
            'z Hledání (stažené skladby se sem přidávají samy).',
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListenableBuilder(
        listenable: _collection,
        builder: (context, _) {
          final visible = _collection.apply(_items);
          final hasMore = !_collection.isModified && _items.length < _total;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: TrackCollectionToolbar(
                  controller: _collection,
                  allTracks: _items,
                  visibleTracks: visible,
                  sourceLabel: _librarySourceLabel,
                  onRemoveSelected: (selected) => confirmRemoveFromLibrary(context, selected),
                  removeLabel: 'Odebrat z knihovny',
                  showFilter: false,
                  trailing: ViewModeToggle(mode: _viewMode, onChanged: (mode) => setState(() => _viewMode = mode)),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xxs),
                  child: Text(
                    _collection.isModified && _items.length < _total
                        ? 'Načítám celou knihovnu… ${_items.length}/$_total'
                        : songsCount(_total),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              if (visible.isEmpty)
                const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Filtru nic neodpovídá.'))
              else if (_viewMode == ViewMode.list || _collection.selecting)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  sliver: SliverList.builder(
                    itemCount: visible.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= visible.length) {
                        if (!_loading) WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                        return const InlineSpinner();
                      }
                      final r = visible[index];
                      return TrackTile(
                        recording: r,
                        queueRecordings: visible,
                        sourceLabel: _librarySourceLabel,
                        selectionMode: _collection.selecting,
                        selected: _collection.isSelected(r.id),
                        onSelectedChanged: (value) => _collection.toggle(r.id, value),
                      );
                    },
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns(MediaQuery.of(context).size.width),
                      childAspectRatio: 0.72,
                      crossAxisSpacing: AppSpacing.sm,
                      mainAxisSpacing: AppSpacing.sm,
                    ),
                    itemCount: visible.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= visible.length) {
                        if (!_loading) WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                        return const InlineSpinner();
                      }
                      return TrackTile(
                        layout: TrackTileLayout.card,
                        recording: visible[index],
                        queueRecordings: visible,
                        sourceLabel: _librarySourceLabel,
                        // Modulo -- na 1000+ položkách by pozdější dlaždice
                        // čekaly na nástupní animaci celé minuty.
                        animationIndex: index % 12,
                      );
                    },
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
              SliverToBoxAdapter(child: SizedBox(height: navBottomInset(context))),
            ],
          );
        },
      ),
    );
  }
}

/// Přepínač mřížka/seznam nad alby/interprety. Vlastní filtr tu není --
/// hledá se horním polem "Hledat v knihovně".
class _GridViewBar extends StatelessWidget {
  const _GridViewBar({required this.viewMode, required this.onViewMode});

  final ViewMode viewMode;
  final ValueChanged<ViewMode> onViewMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: ViewModeToggle(mode: viewMode, onChanged: onViewMode),
      ),
    );
  }
}

class _AlbumsTab extends ConsumerStatefulWidget {
  const _AlbumsTab();

  @override
  ConsumerState<_AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends ConsumerState<_AlbumsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  ViewMode _viewMode = ViewMode.grid;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final albums = ref.watch(_localAlbumsProvider);
    return albums.when(
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(icon: Symbols.album_rounded, message: 'Zatím žádná alba – spusť sken v Profilu.');
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(_localAlbumsProvider),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _GridViewBar(
                  viewMode: _viewMode,
                  onViewMode: (mode) => setState(() => _viewMode = mode),
                ),
              ),
              if (items.isEmpty)
                const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Filtru nic neodpovídá.'))
              else if (_viewMode == ViewMode.grid)
                SliverPadding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns(MediaQuery.of(context).size.width),
                      childAspectRatio: 0.72,
                      crossAxisSpacing: AppSpacing.sm,
                      mainAxisSpacing: AppSpacing.sm,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final album = items[index];
                      return MediaCard(
                        title: album.title,
                        subtitle: '${album.artistName} · ${songsCount(album.trackCount)}',
                        imageUrl: album.coverImageUrl,
                        artworkKey: (releaseId: album.id, artistId: album.artistId),
                        onTap: () => context.push('/releases/${album.id}'),
                        onLongPress: () => showCollectionActions(
                          context,
                          kind: CollectionKind.album,
                          id: album.id,
                          title: album.title,
                          subtitle: album.artistName,
                          imageUrl: album.coverImageUrl,
                        ),
                        animationIndex: index % 12,
                      );
                    },
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
                  sliver: SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final album = items[index];
                      return MediaCard(
                        layout: MediaCardLayout.row,
                        title: album.title,
                        subtitle: '${album.artistName} · ${songsCount(album.trackCount)}',
                        imageUrl: album.coverImageUrl,
                        artworkKey: (releaseId: album.id, artistId: album.artistId),
                        onTap: () => context.push('/releases/${album.id}'),
                        onLongPress: () => showCollectionActions(
                          context,
                          kind: CollectionKind.album,
                          id: album.id,
                          title: album.title,
                          subtitle: album.artistName,
                          imageUrl: album.coverImageUrl,
                        ),
                      );
                    },
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: navBottomInset(context))),
            ],
          ),
        );
      },
      loading: () => const LoadingState(),
      error: (error, stack) => ErrorState(
        message: 'Alba se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(_localAlbumsProvider),
      ),
    );
  }
}

class _ArtistsTab extends ConsumerStatefulWidget {
  const _ArtistsTab();

  @override
  ConsumerState<_ArtistsTab> createState() => _ArtistsTabState();
}

class _ArtistsTabState extends ConsumerState<_ArtistsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  ViewMode _viewMode = ViewMode.grid;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final artists = ref.watch(_localArtistsProvider);
    return artists.when(
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
              icon: Symbols.person_rounded, message: 'Zatím žádní interpreti – spusť sken v Profilu.');
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(_localArtistsProvider),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _GridViewBar(
                  viewMode: _viewMode,
                  onViewMode: (mode) => setState(() => _viewMode = mode),
                ),
              ),
              if (items.isEmpty)
                const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Filtru nic neodpovídá.'))
              else if (_viewMode == ViewMode.grid)
                SliverPadding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns(MediaQuery.of(context).size.width),
                      childAspectRatio: 0.8,
                      crossAxisSpacing: AppSpacing.sm,
                      mainAxisSpacing: AppSpacing.sm,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final artist = items[index];
                      return MediaCard(
                        shape: MediaCardShape.circle,
                        placeholderIcon: Symbols.person_rounded,
                        title: artist.name,
                        subtitle: songsCount(artist.trackCount),
                        imageUrl: artist.imageUrl,
                        artworkKey: (releaseId: null, artistId: artist.id),
                        onTap: () => context.push('/artists/${artist.id}'),
                        animationIndex: index % 12,
                      );
                    },
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
                  sliver: SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final artist = items[index];
                      return MediaCard(
                        layout: MediaCardLayout.row,
                        shape: MediaCardShape.circle,
                        placeholderIcon: Symbols.person_rounded,
                        title: artist.name,
                        subtitle: songsCount(artist.trackCount),
                        imageUrl: artist.imageUrl,
                        artworkKey: (releaseId: null, artistId: artist.id),
                        onTap: () => context.push('/artists/${artist.id}'),
                      );
                    },
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: navBottomInset(context))),
            ],
          ),
        );
      },
      loading: () => const LoadingState(),
      error: (error, stack) => ErrorState(
        message: 'Interprety se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(_localArtistsProvider),
      ),
    );
  }
}

/// Vlastní playlisty (`GET /playlists`) a pod nimi sekce "Sdílené ze
/// Spotify" (přidané z odkazu -- s autorem a jejich obalem). Dřív samostatný
/// tab, to bylo moc (živě nahlášeno).
class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nový playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Název'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          GlassButton(
              label: 'Zrušit',
              style: GlassButtonStyle.plain,
              compact: true,
              onPressed: () => Navigator.of(context).pop()),
          GlassButton(
            label: 'Vytvořit',
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    final created = await ref.read(playlistsRepositoryProvider).create(title);
    ref.invalidate(myPlaylistsProvider);
    if (context.mounted) context.push('/playlists/${created.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(myPlaylistsProvider);
    // Připnuté nahoře: Oblíbené + Poslechnout později.
    const liked = Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.xs),
      child: Column(
        children: [
          LikedSongsCard(),
          SizedBox(height: AppSpacing.sm),
          ListenLaterCard(),
          SizedBox(height: AppSpacing.sm),
          SharedPlaylistsCard(),
        ],
      ),
    );
    Widget card(PlaylistSummaryModel playlist) {
      final artists = playlist.artistNames;
      final who = artists.isEmpty
          ? 'Playlist'
          : artists.length < 3
              ? artists.join(', ')
              : '${artists.take(2).join(', ')} a další';
      return MediaCard(
        layout: MediaCardLayout.row,
        placeholderIcon: Symbols.queue_music_rounded,
        artwork: PlaylistArtwork(
          title: playlist.title,
          coverUrls: playlist.coverUrls,
          showTitle: false,
          badge: playlist.isLegacy ? 'před 2016' : null,
        ),
        title: playlist.title,
        // Sdílené: autor ze Spotify ("Ze Spotify · jméno").
        subtitle: playlist.isShared && playlist.description != null
            ? '${playlist.description} · ${songsCount(playlist.itemCount)}'
            : '$who · ${songsCount(playlist.itemCount)}',
        onTap: () => context.push('/playlists/${playlist.id}'),
        onLongPress: () => showCollectionActions(
          context,
          kind: CollectionKind.playlist,
          id: playlist.id,
          title: playlist.title,
          imageUrl: playlist.coverUrls.firstOrNull,
        ),
      );
    }

    // "Nový playlist…" jako první řádek seznamu (jako Apple Music) -- dřív
    // plovoucí tlačítko, které zakrývalo poslední playlist a vedle skla
    // lišty působilo cize.
    final scheme = Theme.of(context).colorScheme;
    final create = MediaCard(
      layout: MediaCardLayout.row,
      placeholderIcon: Symbols.add_rounded,
      artwork: DecoratedBox(
        decoration: ShapeDecoration(shape: AppShapes.of(Expressive.cornerMedium), color: scheme.secondaryContainer),
        child: Center(child: Icon(Symbols.add_rounded, size: 32, color: scheme.onSecondaryContainer)),
      ),
      title: 'Nový playlist…',
      onTap: () => _createPlaylist(context, ref),
    );

    return Scaffold(
      body: playlists.when(
        data: (all) {
          final own = [
            for (final p in all)
              if (!p.isShared) p
          ];
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(myPlaylistsProvider);
              ref.invalidate(likedSongsProvider);
            },
            child: ListView(
              padding: EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, 96 + navBottomInset(context)),
              children: [
                liked,
                create,
                for (final p in own) card(p),
              ],
            ),
          );
        },
        loading: () => const LoadingState(),
        error: (error, stack) => ErrorState(
          message: 'Playlisty se nepodařilo načíst.',
          error: error,
          onRetry: () => ref.invalidate(myPlaylistsProvider),
        ),
      ),
    );
  }
}

/// Taby Knihovny jako segmentový ovladač napojený na `DefaultTabController`
/// (obsah zůstává `TabBarView` -- swipe mezi taby funguje dál).
class _LibraryTabSegments extends StatelessWidget {
  const _LibraryTabSegments();

  static const _labels = ['Skladby', 'Alba', 'Interpreti', 'Playlisty', 'Offline'];

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => GlassSegmentedControl<int>(
        segments: [for (var i = 0; i < _labels.length; i++) GlassSegment(value: i, label: _labels[i])],
        selected: controller.index,
        onChanged: controller.animateTo,
      ),
    );
  }
}


/// Admin: pohled Knihovny -- Moje (klasická knihovna) / Staženo (co sám
/// stáhl) / Vše na serveru. Ostatní profily ho zatím nevidí ("Staženo" pro
/// ně přijde s offline režimem v nativní appce).
class _LibraryScopeToggle extends ConsumerWidget {
  const _LibraryScopeToggle();

  static const _labels = {
    LibraryScope.mine: ('Moje', Symbols.person_rounded, 'Co sis přidal do knihovny a lajkl'),
    LibraryScope.downloaded: ('Staženo', Symbols.download_done_rounded, 'Všechno, co sis stáhl nebo pustil'),
    LibraryScope.all: ('Vše na serveru', Symbols.dns_rounded, 'Všechno stažené, i od ostatních profilů'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(authProvider).valueOrNull?.user?.role != 'admin') return const SizedBox.shrink();
    final scope = ref.watch(libraryScopeProvider);
    final (label, icon, _) = _labels[scope]!;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: GlassButton(
        label: label,
        icon: icon,
        style: GlassButtonStyle.tonal,
        compact: true,
        onPressed: () => showGlassSheet<void>(
          context,
          builder: (sheetContext) => GlassSheet(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in _labels.entries)
                  ListTile(
                    leading: Icon(entry.value.$2),
                    title: Text(entry.value.$1),
                    subtitle: Text(entry.value.$3),
                    trailing: entry.key == scope ? const Icon(Symbols.check_rounded) : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      ref.read(libraryScopeProvider.notifier).set(entry.key);
                    },
                  ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
