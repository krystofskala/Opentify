import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/artist_actions.dart';
import 'soulseek_card.dart';
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
import 'pinned_tile.dart' show PinnedGrid;
import 'shazam_collection_screen.dart' show ShazamCard;
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
import '../../state/app_mode.dart';
import 'offline_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/toast.dart';
import '../../widgets/sort_button.dart';
import '../../state/favorite_artists_controller.dart';
import '../../data/library_repository.dart' show LocalArtist;
import '../../widgets/playlist_removal.dart';
import '../../state/liked_songs_controller.dart';
import '../../widgets/edge_fade_scroll.dart';

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
class LocalLibraryScreen extends ConsumerStatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  ConsumerState<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

/// Hledání přes CELOU knihovnu (backend `GET /library/search`, bez
/// diakritiky) -- ne jen přes právě načtenou stránku skladeb. Během hledání
/// taby nahradí čipy rozsahu a obsah seskupené výsledky, stejné jako v Hledání.
class _LocalLibraryScreenState extends ConsumerState<LocalLibraryScreen> {
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
    final offline = ref.watch(libraryScopeProvider) == LibraryScope.offline;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: SectionAppBar(
          'Knihovna',
          // Admin: celá sdílená knihovna na serveru, nebo jen ta jeho.
          actions: const [LibraryScopeToggle(), AppModeToggle()],
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(offline ? 0 : 64 + 48),
            child: offline ? const SizedBox.shrink() : Column(
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
        body: offline ? const OfflineTab() : Stack(
          children: [
            Offstage(
              offstage: searching,
              child: const TabBarView(
                children: [_SongsTab(), _AlbumsTab(), _ArtistsTab(), _PlaylistsTab()],
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

  // Ne `final`: obnova dává nový seznam -- `TrackCollectionController.apply`
  // kešuje podle identity+délky a stejně dlouhý obnovený seznam by ukázal
  // starý výsledek.
  List<RecordingModel> _items = [];
  final _collection = TrackCollectionController();
  int _total = 0;
  bool _loading = false;

  /// Právě běžící `_loadMore` -- `_loadAll` na něj počká místo toho, aby
  /// skončil (jinak "Načítám celou knihovnu…" viselo navždy).
  Future<void>? _inFlight;
  bool _loadingAll = false;
  bool _initialLoadDone = false;
  Object? _error;
  ViewMode _viewMode = ViewMode.list;

  /// "Oblíbené" -- jen skladby se srdíčkem (jako "Oblíbení" u interpretů).
  bool _likedOnly = false;

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

  /// Roste s každým `_refresh` -- stránka z načítání, které běželo před
  /// obnovou, se zahodí (jinak se do vyčištěného seznamu přidala stará data).
  int _generation = 0;

  Future<void> _loadMore({int pageSize = _pageSize}) {
    if (_loading) return _inFlight ?? Future.value();
    final future = _fetchPage(pageSize);
    _inFlight = future;
    return future;
  }

  Future<void> _fetchPage(int pageSize) async {
    final gen = _generation;
    setState(() => _loading = true);
    try {
      final page = await ref.read(libraryRepositoryProvider).localTracks(limit: pageSize, offset: _items.length);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _error = null;
      });
    } catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) {
        setState(() {
          _loading = false;
          _initialLoadDone = true;
        });
      }
    }
  }

  Future<void> _loadAll() async {
    if (_loadingAll) return;
    _loadingAll = true;
    final gen = _generation;
    try {
      // Rozběhnuté stránkování nejdřív doběhne, ať se nepočítá jako "nic nepřibylo".
      if (_loading) await _inFlight;
      while (mounted && gen == _generation && _items.length < _total && _error == null) {
        final before = _items.length;
        await _loadMore(pageSize: _fullLoadPageSize);
        if (_items.length == before) break;
      }
    } finally {
      _loadingAll = false;
    }
  }

  /// Načítá se celá knihovna (filtr/řazení/Oblíbené) a ještě není hotová.
  bool get _needsAll => (_collection.isModified || _likedOnly) && _items.length < _total;

  Future<void> _refresh() async {
    _generation++;
    setState(() {
      _loading = false;
      _items = [];
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
        message: 'Zatím žádné skladby – najdi si něco v Hledání a přidej do knihovny '
            '(stažené skladby se sem přidávají samy).',
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListenableBuilder(
        listenable: _collection,
        builder: (context, _) {
          final liked = ref.watch(likedSongsControllerProvider).valueOrNull ?? const <String>{};
          final applied = _collection.apply(_items);
          final visible = _likedOnly ? [for (final r in applied) if (liked.contains(r.id)) r] : applied;
          final hasMore = !_collection.isModified && !_likedOnly && _items.length < _total;
          return CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              // Server (admin): sdílení na Soulseeku -- kdo si co od nás stáhl.
              if (ref.watch(libraryScopeProvider) == LibraryScope.all) const SliverToBoxAdapter(child: SoulseekCard()),
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
                  // Počet + filtr "Oblíbené" (na liště nad tím už není místo).
                  child: Row(
                    children: [
                      // Dotažení celé knihovny selhalo -- jinak by "Načítám…" viselo.
                      if (_needsAll && _error != null) ...[
                        Expanded(
                          child: Text(
                            'Celou knihovnu se nepodařilo načíst (${_items.length}/$_total).',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                        GlassButton(
                          label: 'Zkusit znovu',
                          icon: Symbols.refresh_rounded,
                          style: GlassButtonStyle.plain,
                          compact: true,
                          onPressed: () {
                            setState(() => _error = null);
                            _loadAll();
                          },
                        ),
                      ] else
                        Expanded(
                          child: Text(
                            _needsAll
                                ? 'Načítám celou knihovnu… ${_items.length}/$_total'
                                : _likedOnly
                                    ? '${songsCount(visible.length)} se srdíčkem'
                                        // Oblíbené (playlist) počítá i nestažené -- ať čísla nevypadají rozbitě.
                                        '${!_collection.isModified && liked.length > visible.length ? ' · ${liked.length - visible.length} ještě nestažené' : ''}'
                                    : songsCount(_total),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      FilterChip(
                        avatar: const Icon(Symbols.favorite_rounded, size: 16),
                        label: const Text('Oblíbené'),
                        tooltip: 'Jen skladby se srdíčkem',
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        selected: _likedOnly,
                        onSelected: (on) {
                          setState(() => _likedOnly = on);
                          // Filtr nad celou knihovnou, ne jen první stránkou.
                          if (on && _items.length < _total) _loadAll();
                        },
                      ),
                    ],
                  ),
                ),
              ),
              // Prázdno jen zatím (zbytek knihovny se dotahuje) -- skeleton,
              // ne "Zatím žádné oblíbené".
              if (visible.isEmpty && _needsAll && _error == null)
                const SliverToBoxAdapter(child: SkeletonTrackList())
              else if (visible.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    compact: true,
                    message: _likedOnly ? 'Zatím žádné oblíbené – dej skladbě srdíčko.' : 'Filtru nic neodpovídá.',
                  ),
                )
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
                        selectionNumber: _collection.orderOf(r.id),
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
                      crossAxisCount: _gridColumns(MediaQuery.sizeOf(context).width),
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
                        animationIndex: index < 12 ? index : null, // jen první obrazovka, ne při scrollu
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
  const _GridViewBar({required this.viewMode, required this.onViewMode, this.sort, this.filter});

  final ViewMode viewMode;
  final ValueChanged<ViewMode> onViewMode;

  /// Řazení vlevo (jako u Skladeb).
  final Widget? sort;

  /// Filtr vedle řazení (Alba: "Celá alba").
  final Widget? filter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: Row(
        children: [
          // Řazení + filtr jdou na úzkém telefonu posunout prstem do strany
          // (rozplynutý okraj ukáže, že tam něco je).
          Expanded(
            child: EdgeFadeScroll(
              child: Row(
                children: [
                  if (sort != null) sort!,
                  if (filter != null) ...[const SizedBox(width: AppSpacing.xs), filter!],
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          ViewModeToggle(mode: viewMode, onChanged: onViewMode),
        ],
      ),
    );
  }
}

/// Řazení alb, interpretů a playlistů (Skladby mají vlastní v toolbaru).
enum LibrarySort { added, name, artist, count }

const _librarySortLabels = {
  LibrarySort.added: 'Přidáno',
  LibrarySort.name: 'Název',
  LibrarySort.artist: 'Interpret',
  LibrarySort.count: 'Počet skladeb',
};

final _librarySortProvider = StateProvider.family<LibrarySort, String>((ref, tab) => LibrarySort.added);

/// Knihovna › Interpreti › "Oblíbení": jen interpreti se srdíčkem.
final _favoriteArtistsOnlyProvider = StateProvider<bool>((ref) => false);

/// Knihovna › Alba › "Celá alba": jen alba, ze kterých má uživatel všechny skladby.
final _completeAlbumsOnlyProvider = StateProvider<bool>((ref) => false);

/// Novější první; bez data na konec.
int _byAddedDesc(String? a, String? b) => (b ?? '').compareTo(a ?? '');

int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

class _SortButton extends ConsumerWidget {
  const _SortButton({required this.tab, required this.options, this.labelOverrides = const {}});

  final String tab;
  final List<LibrarySort> options;

  /// Jiný popisek pro tenhle tab (Playlisty: "Upraveno").
  final Map<LibrarySort, String> labelOverrides;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(_librarySortProvider(tab));
    return SortButton<LibrarySort>(
      value: current,
      labels: {for (final option in options) option: labelOverrides[option] ?? _librarySortLabels[option]!},
      onChanged: (value) => ref.read(_librarySortProvider(tab).notifier).state = value,
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
    final sort = ref.watch(_librarySortProvider('albums'));
    final completeOnly = ref.watch(_completeAlbumsOnlyProvider);
    return albums.when(
      data: (loaded) {
        final items = [for (final a in loaded) if (!completeOnly || a.complete) a]..sort((a, b) => switch (sort) {
              LibrarySort.added => _byAddedDesc(a.addedAt, b.addedAt),
              LibrarySort.name => _byName(a.title, b.title),
              LibrarySort.artist => _byName(a.artistName, b.artistName) != 0
                  ? _byName(a.artistName, b.artistName)
                  : _byName(a.title, b.title),
              LibrarySort.count => b.trackCount.compareTo(a.trackCount),
            });
        if (loaded.isEmpty) {
          return const EmptyState(icon: Symbols.album_rounded, message: 'Zatím žádná alba – přidej si nějaké z Hledání.');
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(_localAlbumsProvider),
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: _GridViewBar(
                  viewMode: _viewMode,
                  onViewMode: (mode) => setState(() => _viewMode = mode),
                  sort: const _SortButton(
                    tab: 'albums',
                    options: [LibrarySort.added, LibrarySort.name, LibrarySort.artist, LibrarySort.count],
                  ),
                  filter: FilterChip(
                    label: const Text('Celá alba'),
                    tooltip: 'Jen alba, ze kterých máš všechny skladby',
                    selected: completeOnly,
                    onSelected: (on) => ref.read(_completeAlbumsOnlyProvider.notifier).state = on,
                  ),
                ),
              ),
              if (items.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    compact: true,
                    message: completeOnly ? 'Zatím žádné celé album.' : 'Filtru nic neodpovídá.',
                  ),
                )
              else if (_viewMode == ViewMode.grid)
                SliverPadding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns(MediaQuery.sizeOf(context).width),
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
                          // V Knihovně je album vždy (aspoň částečně) -- jinak
                          // menu nenabídlo "Odebrat z knihovny".
                          inLibrary: true,
                        ),
                        animationIndex: index < 12 ? index : null, // jen první obrazovka, ne při scrollu
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
                          // V Knihovně je album vždy (aspoň částečně) -- jinak
                          // menu nenabídlo "Odebrat z knihovny".
                          inLibrary: true,
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
    final sort = ref.watch(_librarySortProvider('artists'));
    final favoritesOnly = ref.watch(_favoriteArtistsOnlyProvider);
    final favorites = ref.watch(favoriteArtistsProvider).valueOrNull ?? const [];
    return artists.when(
      data: (loaded) {
        final byId = {for (final a in loaded) a.id: a};
        // Oblíbení i bez skladeb v knihovně (srdíčko dané ze stránky interpreta).
        final source = favoritesOnly
            ? [
                for (final f in favorites)
                  byId[f.id] ??
                      LocalArtist(id: f.id, name: f.name, imageUrl: f.imageUrl, trackCount: 0, addedAt: f.addedAt),
              ]
            : loaded;
        final items = [...source]..sort((a, b) => switch (sort) {
              LibrarySort.added => _byAddedDesc(a.addedAt, b.addedAt),
              LibrarySort.count => b.trackCount.compareTo(a.trackCount),
              _ => _byName(a.name, b.name),
            });
        if (loaded.isEmpty && favorites.isEmpty) {
          return const EmptyState(
              icon: Symbols.person_rounded, message: 'Zatím žádní interpreti – přidej si hudbu z Hledání.');
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(_localArtistsProvider),
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: _GridViewBar(
                  viewMode: _viewMode,
                  onViewMode: (mode) => setState(() => _viewMode = mode),
                  sort: const _SortButton(
                    tab: 'artists',
                    options: [LibrarySort.added, LibrarySort.name, LibrarySort.count],
                  ),
                  filter: FilterChip(
                    label: const Text('Oblíbení'),
                    tooltip: 'Jen interpreti se srdíčkem',
                    selected: favoritesOnly,
                    onSelected: (on) => ref.read(_favoriteArtistsOnlyProvider.notifier).state = on,
                  ),
                ),
              ),
              if (items.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    compact: true,
                    message: favoritesOnly
                        ? 'Zatím žádní oblíbení – dej srdíčko na stránce interpreta.'
                        : 'Filtru nic neodpovídá.',
                  ),
                )
              else if (_viewMode == ViewMode.grid)
                SliverPadding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumns(MediaQuery.sizeOf(context).width),
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
                        onLongPress: () =>
                            showArtistActions(context, id: artist.id, name: artist.name, imageUrl: artist.imageUrl),
                        animationIndex: index < 12 ? index : null, // jen první obrazovka, ne při scrollu
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
                        onLongPress: () =>
                            showArtistActions(context, id: artist.id, name: artist.name, imageUrl: artist.imageUrl),
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
    if (title == null || title.isEmpty) {
      if (title != null && context.mounted) {
        showToast(ScaffoldMessenger.maybeOf(context), 'Playlist potřebuje název.');
      }
      return;
    }
    try {
      final created = await ref.read(playlistsRepositoryProvider).create(title);
      ref.invalidate(myPlaylistsProvider);
      if (context.mounted) context.push('/playlists/${created.id}');
    } catch (_) {
      if (context.mounted) {
        showToast(ScaffoldMessenger.maybeOf(context), 'Playlist se nepodařilo vytvořit.');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(myPlaylistsProvider);
    // Připnuté nahoře v mřížce 2×2 (pod nimi je tak vidět víc playlistů).
    const liked = Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.xs),
      child: PinnedGrid(
        children: [LikedSongsCard(), ListenLaterCard(), SharedPlaylistsCard(), ShazamCard()],
      ),
    );
    final grid = ref.watch(_playlistGridProvider);
    Widget card(PlaylistSummaryModel playlist) {
      final artists = playlist.artistNames;
      final who = artists.isEmpty
          ? 'Playlist'
          : artists.length < 3
              ? artists.join(', ')
              : '${artists.take(2).join(', ')} a další';
      return MediaCard(
        layout: grid ? MediaCardLayout.card : MediaCardLayout.row,
        placeholderIcon: Symbols.queue_music_rounded,
        artwork: PlaylistArtwork(
          title: playlist.title,
          coverUrls: playlist.coverUrls,
          showTitle: false,
          badge: playlist.isLegacy ? 'před 2016' : null,
        ),
        title: playlist.title,
        // Sdílené: autor ze Spotify ("Ze Spotify · jméno").
        subtitle: playlist.pinned
            ? 'Aktualizuje se · ${songsCount(playlist.itemCount)}'
            : playlist.collab
                ? 'Společný${playlist.ownerName != null ? ' · od ${playlist.ownerName}' : ''} · ${songsCount(playlist.itemCount)}'
                : playlist.isShared && playlist.description != null
                ? '${playlist.description} · ${songsCount(playlist.itemCount)}'
                : '$who · ${songsCount(playlist.itemCount)}',
        onTap: () => context.push('/playlists/${playlist.id}'),
        // Stejné menu jako ⋯ v detailu playlistu (Upravit, Pozvat, Opustit…).
        onLongPress: () => showPlaylistSummaryActions(context, ref, playlist),
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
          final sort = ref.watch(_librarySortProvider('playlists'));
          final own = [
            for (final p in all)
              if (!p.isShared) p
          ]..sort((a, b) => switch (sort) {
              // Backend dává jen `updatedAt` -- proto popisek "Upraveno", ne "Přidáno".
              LibrarySort.added => _byAddedDesc(a.updatedAt, b.updatedAt),
              LibrarySort.count => b.itemCount.compareTo(a.itemCount),
              _ => _byName(a.title, b.title),
            });
          // Slivery (jako Alba) -- stovky playlistů se staví jen na obrazovce,
          // ne všechny najednou v Column.
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(myPlaylistsProvider);
              ref.invalidate(likedSongsProvider);
              // Sada srdíček zvlášť -- karta Oblíbené počítá z ní.
              await ref.read(likedSongsControllerProvider.notifier).refresh();
            },
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, 0),
                  sliver: SliverList.list(
                    children: [
                      liked,
                      // Moje playlisty: seznam, nebo galerie (mřížka obalů).
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, AppSpacing.xs, 0),
                        child: Row(
                          children: [
                            Expanded(child: Text('Moje playlisty', style: Theme.of(context).textTheme.titleMedium)),
                            const _SortButton(
                              tab: 'playlists',
                              options: [LibrarySort.added, LibrarySort.name, LibrarySort.count],
                              labelOverrides: {LibrarySort.added: 'Upraveno'},
                            ),
                            const SizedBox(width: 4),
                            ViewModeToggle(
                              mode: grid ? ViewMode.grid : ViewMode.list,
                              onChanged: (mode) => ref.read(_playlistGridProvider.notifier).set(mode == ViewMode.grid),
                            ),
                          ],
                        ),
                      ),
                      create,
                    ],
                  ),
                ),
                if (!grid)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    sliver: SliverList.builder(
                      itemCount: own.length,
                      itemBuilder: (context, index) => card(own[index]),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _gridColumns(MediaQuery.sizeOf(context).width),
                        childAspectRatio: 0.72,
                        crossAxisSpacing: AppSpacing.sm,
                        mainAxisSpacing: AppSpacing.sm,
                      ),
                      itemCount: own.length,
                      itemBuilder: (context, index) => card(own[index]),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: 96 + navBottomInset(context))),
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

  static const _labels = ['Skladby', 'Alba', 'Interpreti', 'Playlisty'];

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
class LibraryScopeToggle extends ConsumerWidget {
  const LibraryScopeToggle({super.key});

  static const _labels = {
    LibraryScope.mine: ('Moje', Symbols.person_rounded, 'Co sis přidal do knihovny a lajkl'),
    LibraryScope.downloaded: ('Staženo', Symbols.download_done_rounded, 'Všechno, co sis stáhl nebo pustil'),
    LibraryScope.all: ('Server', Symbols.dns_rounded, 'Všechno stažené na serveru, i od ostatních profilů'),
    LibraryScope.offline: ('Offline', Symbols.download_for_offline_rounded, 'Uložené v tomhle zařízení (hraje i bez internetu)'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(authProvider).valueOrNull?.user?.role == 'admin';
    // Offline (v zařízení) mají všichni; Staženo a Server jen admin.
    final options = {
      for (final e in _labels.entries)
        if (admin || e.key == LibraryScope.mine || e.key == LibraryScope.offline) e.key: e.value,
    };
    var scope = ref.watch(libraryScopeProvider);
    if (!options.containsKey(scope)) scope = LibraryScope.mine;
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
                for (final entry in options.entries)
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


/// Knihovna › Playlisty: seznam, nebo galerie (pamatuje se).
class _PlaylistGridController extends StateNotifier<bool> {
  _PlaylistGridController() : super(false) {
    _load();
  }

  static const _prefKey = 'library.playlists_grid';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool grid) async {
    state = grid;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, grid);
    } catch (_) {}
  }
}

final _playlistGridProvider = StateNotifierProvider<_PlaylistGridController, bool>((ref) => _PlaylistGridController());
