import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/artist_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/playlists_repository.dart' show looksLikeSpotifyLink;
import '../../widgets/spotify_link_import.dart';
import '../../core/api_client.dart';
import '../browse/browse_category_screen.dart' show DeezerPlaylistTile;
import '../browse/browse_grid.dart';
import '../../models/recording_model.dart';
import '../../models/search_result.dart';
import '../../state/providers.dart';
import '../../state/search_history_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/library_search_results.dart';
import '../../widgets/media_card.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart' show foldForSearch;
import '../../widgets/track_tile.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../theme/glass_tokens.dart';
import '../../widgets/collection_actions.dart';
import '../browse/tag_screen.dart' show tagRoute;
import '../games/games_screen.dart' show WorkCover;

const _searchSourceLabel = 'Výsledky hledání';

enum SearchFilter { all, tracks, artists, albums }

const _filterLabels = {
  SearchFilter.all: 'Vše',
  SearchFilter.tracks: 'Skladby',
  SearchFilter.artists: 'Interpreti',
  SearchFilter.albums: 'Alba',
};

const _entityTypeFor = {
  SearchFilter.tracks: 'recording',
  SearchFilter.artists: 'artist',
  SearchFilter.albums: 'release',
};

const _releaseTypeLabels = {'album': 'Album', 'ep': 'EP', 'single': 'Singl', 'compilation': 'Kompilace'};

/// Aktuální dotaz do vyhledávání (s debounce z textového pole).
final searchQueryProvider = StateProvider.autoDispose<String>((ref) => '');
final searchFilterProvider = StateProvider.autoDispose<SearchFilter>((ref) => SearchFilter.all);

/// "Jen moje knihovna" -- místo globálního katalogu hledá jen v tom, co
/// už je v knihovně (`GET /library/search`). Přežívá přepnutí záložky
/// (ne `autoDispose`), ať se uživateli nevrací zpátky na katalog.
final searchLibraryOnlyProvider = StateProvider<bool>((ref) => false);

const _libraryScopeFor = {
  SearchFilter.all: LibrarySearchScope.all,
  SearchFilter.tracks: LibrarySearchScope.tracks,
  SearchFilter.artists: LibrarySearchScope.artists,
  SearchFilter.albums: LibrarySearchScope.albums,
};

typedef _SectionKey = ({String query, String type, int limit});

/// Jeden typ výsledků zvlášť -- backend u kombinovaného dotazu bez `type`
/// ořízne výsledky na `limit` CELKEM (interpreti jdou první a zbytek
/// vytlačí), takže sekce "Vše" se skládá ze tří samostatných dotazů, které
/// se navíc načítají a zobrazují nezávisle na sobě.
final searchSectionProvider = FutureProvider.autoDispose.family<List<SearchResultItem>, _SectionKey>((ref, key) async {
  final result = await ref.watch(catalogRepositoryProvider).search(key.query, entityType: key.type, limit: key.limit);
  if (result.didYouMean != null) ref.read(searchCorrectionProvider(key.query).notifier).state = result.didYouMean;
  return result.results;
});

/// "Výsledky pro …" -- dotaz opravený přes Last.fm (překlep ve jménu).
final searchCorrectionProvider = StateProvider.autoDispose.family<String?, String>((ref, query) => null);

/// Hledání v globálním katalogu -- živé výsledky s debounce, sekce podle
/// typu (Skladby / Interpreti / Alba) + filtrovací čipy, našeptávání z
/// historie. Skladby se vykreslují stejným `TrackTile` jako všude jinde.
/// Rozložení podle Spotube's `pages/search` (BSD-4), vlastní implementace.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  static const _debounceDuration = Duration(milliseconds: 350);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Vložený odkaz na Spotify se nehledá, ale rovnou naimportuje (playlist
  /// se objeví v Knihovně › Sdílené a otevře se).
  bool _maybeSpotifyLink(String value) {
    if (!looksLikeSpotifyLink(value)) return false;
    _debounce?.cancel();
    _controller.clear();
    _focusNode.unfocus();
    setState(() {});
    importSpotifyLink(context, ref, value);
    return true;
  }

  void _onChanged(String value) {
    if (_maybeSpotifyLink(value)) return;
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      if (!mounted) return;
      ref.read(searchQueryProvider.notifier).state = value;
      // Dotaz, u kterého uživatel na chvíli zůstal, se ukládá do historie --
      // ne jen odeslané Enterem (na mobilu se Enter skoro nemačká).
      if (value.trim().length >= 3) {
        Timer(const Duration(seconds: 2), () {
          if (mounted && ref.read(searchQueryProvider) == value) {
            ref.read(searchHistoryControllerProvider.notifier).add(value);
          }
        });
      }
    });
  }

  void _runSearch(String value) {
    if (_maybeSpotifyLink(value)) return;
    _debounce?.cancel();
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(offset: value.length);
    ref.read(searchQueryProvider.notifier).state = value;
    if (value.trim().isNotEmpty) ref.read(searchHistoryControllerProvider.notifier).add(value);
    _focusNode.unfocus();
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    ref.read(searchQueryProvider.notifier).state = '';
    ref.read(searchFilterProvider.notifier).state = SearchFilter.all;
    _focusNode.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider).trim();
    final filter = ref.watch(searchFilterProvider);
    final libraryOnly = ref.watch(searchLibraryOnlyProvider);

    return Scaffold(
      appBar: SectionAppBar(
        'Hledat',
        // "Jen moje knihovna" vpravo nahoře (toggle tlačítko), ať nezužuje
        // pole ani řádek rozsahů.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: GlassIconButton(
              icon: Symbols.library_music_rounded,
              tooltip: 'Jen moje knihovna',
              size: GlassTokens.compactControlHeight,
              iconSize: 20,
              selected: libraryOnly,
              onPressed: () => ref.read(searchLibraryOnlyProvider.notifier).state = !libraryOnly,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(query.isEmpty ? 64 : 112),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                child: _SearchField(
                  controller: _controller,
                  focusNode: _focusNode,
                  onChanged: _onChanged,
                  onSubmitted: _runSearch,
                  onClear: _clear,
                ),
              ),
              if (query.isNotEmpty)
                // Rozsah hledání jako segmentový ovladač (HIG Search fields:
                // "Use a scope bar to filter among clearly defined search
                // categories"). SoundCloud není rozsah, ale sekce ve "Vše".
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: GlassSegmentedControl<SearchFilter>(
                      segments: [
                        for (final f in SearchFilter.values) GlassSegment(value: f, label: _filterLabels[f]!),
                      ],
                      selected: filter,
                      onChanged: (f) => ref.read(searchFilterProvider.notifier).state = f,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      body: AnimatedSwitcher(
        duration: Motion.state.duration,
        switchInCurve: Motion.state,
        switchOutCurve: Motion.state,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, if (current != null) current],
        ),
        child: query.isEmpty
            ? _SearchHistoryView(key: const ValueKey('history'), onPick: _runSearch)
            : libraryOnly
                ? LibrarySearchResults(
                    key: ValueKey('library-$filter-$query'),
                    query: query,
                    scope: _libraryScopeFor[filter]!,
                    onSeeAll: (scope) => ref.read(searchFilterProvider.notifier).state =
                        _libraryScopeFor.entries.firstWhere((e) => e.value == scope).key,
                  )
                : filter == SearchFilter.all
                    ? _AllResults(key: ValueKey('all-$query'), query: query)
                    : _FilteredResults(key: ValueKey('$filter-$query'), query: query, filter: filter),
      ),
    );
  }
}

/// Vyhledávací pole s našeptávačem z historie (Spotube's `AutoComplete`
/// vzor, vlastní implementace přes `RawAutocomplete`).
class _SearchField extends ConsumerWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  static bool _fuzzy(String candidate, String query) {
    final c = foldForSearch(candidate);
    final q = foldForSearch(query.trim());
    if (q.isEmpty || c == q) return false;
    if (c.contains(q)) return true;
    // Podsekvence ("mtlc" -> "metallica") -- tolerantní k překlepům/zkratkám.
    var i = 0;
    for (final ch in c.split('')) {
      if (i < q.length && ch == q[i]) i++;
    }
    return q.length >= 3 && i == q.length;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryControllerProvider);
    return LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<String>(
        textEditingController: controller,
        focusNode: focusNode,
        optionsBuilder: (value) => history.where((h) => _fuzzy(h, value.text)).take(6),
        onSelected: onSubmitted,
        fieldViewBuilder: (context, textController, fieldFocus, onFieldSubmitted) => GlassSearchField(
          controller: textController,
          focusNode: fieldFocus,
          autofocus: true,
          hintText: 'Interpret, album nebo skladba…',
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          onCleared: onClear,
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xxs),
            child: SizedBox(
              width: constraints.maxWidth,
              child: GlassSuggestionsPanel(
                children: [
                  for (final option in options)
                    ListTile(
                      dense: true,
                      leading: const Icon(Symbols.history_rounded, size: 20),
                      title: Text(option),
                      trailing: const Icon(Symbols.north_west_rounded, size: 18),
                      onTap: () => onSelected(option),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Prázdný dotaz -- naposledy hledané jako klikatelné čipy.
class _SearchHistoryView extends ConsumerWidget {
  const _SearchHistoryView({super.key, required this.onPick});
  final void Function(String query) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryControllerProvider);
    // Prázdný dotaz: naposledy hledané + "Procházet" (nálady a žánry).
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
      children: [
        if (history.isNotEmpty) ...[
          SectionHeader(
            'Nedávno hledáno',
            trailing: TextButton(
              onPressed: () => ref.read(searchHistoryControllerProvider.notifier).clear(),
              child: const Text('Vymazat'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final query in history)
                  InputChip(
                    label: Text(query),
                    avatar: const Icon(Symbols.history_rounded, size: 18),
                    onPressed: () => onPick(query),
                    onDeleted: () => ref.read(searchHistoryControllerProvider.notifier).remove(query),
                  ),
              ],
            ),
          ),
        ],
        const BrowseGrid(),
      ],
    );
  }
}

String _errorMessage(Object error) => error is ApiException && error.statusCode == 503
    ? 'MusicBrainz je teď přetížený – zkus to za chvíli znovu.'
    : 'Hledání se nepovedlo.';

/// "Vše" -- tři nezávislé sekce, každá s "Zobrazit vše" do svého filtru.
class _AllResults extends ConsumerWidget {
  const _AllResults({super.key, required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(searchSectionProvider((query: query, type: 'recording', limit: 10)));
    final artists = ref.watch(searchSectionProvider((query: query, type: 'artist', limit: 10)));
    final albums = ref.watch(searchSectionProvider((query: query, type: 'release', limit: 10)));
    void show(SearchFilter f) => ref.read(searchFilterProvider.notifier).state = f;

    final playlists = ref.watch(searchPlaylistsProvider(query));
    final allEmpty = [tracks, artists, albums].every((v) => v.hasValue && v.value!.isEmpty) &&
        playlists.hasValue &&
        playlists.value!.isEmpty &&
        (ref.watch(soundcloudSearchProvider(query)).valueOrNull?.isEmpty ?? !ref.watch(soundcloudSearchProvider(query)).isLoading);
    final allError = [tracks, artists, albums].every((v) => v.hasError);
    if (allEmpty) {
      return EmptyState(icon: Symbols.search_off_rounded, message: 'Pro „$query“ nic nenalezeno.');
    }
    if (allError) {
      return ErrorState(
        message: _errorMessage(tracks.error!),
        onRetry: () {
          for (final type in ['recording', 'artist', 'release']) {
            ref.invalidate(searchSectionProvider((query: query, type: type, limit: 10)));
          }
        },
      );
    }

    final corrected = ref.watch(searchCorrectionProvider(query));
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
      children: [
        if (corrected != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Výsledky pro '),
                TextSpan(text: '„$corrected“', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        _GenreChips(query: query),
        _Section(
          title: 'Skladby',
          value: tracks,
          onSeeAll: () => show(SearchFilter.tracks),
          loading: const SkeletonTrackList(count: 4),
          builder: (items) {
            final recordings = items.map((i) => i.toRecordingModel()).toList();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Column(
                children: [
                  for (final r in recordings.take(5))
                    TrackTile(recording: r, queueRecordings: recordings, sourceLabel: _searchSourceLabel),
                ],
              ),
            );
          },
        ),
        _Section(
          title: 'Interpreti',
          value: artists,
          onSeeAll: () => show(SearchFilter.artists),
          loading: const SkeletonCardRail(height: 180, cardWidth: 130, circle: true),
          builder: (items) => _Rail(height: 180, children: [for (final a in items) _ArtistCard(item: a)]),
        ),
        _Section(
          title: 'Alba',
          value: albums,
          onSeeAll: () => show(SearchFilter.albums),
          loading: const SkeletonCardRail(height: 190, cardWidth: 140),
          builder: (items) => _Rail(height: 190, width: 140, children: [for (final a in items) _ReleaseCard(item: a)]),
        ),
        _WorksSection(query: query),
        _PlaylistsSection(query: query),
        _SoundcloudSection(query: query),
      ],
    );
  }
}

/// Playlisty od lidí i redakce Deezeru -- soundtracky, herní rádia (GTA),
/// tematické výběry. Otevřením se převezmou do katalogu.
class _PlaylistsSection extends ConsumerWidget {
  const _PlaylistsSection({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(searchPlaylistsProvider(query));
    return playlists.when(
      data: (items) => items.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader('Playlisty'),
                _Rail(
                  height: 214,
                  width: 150,
                  children: [for (final p in items) DeezerPlaylistTile(playlist: p)],
                ),
              ],
            ),
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SectionHeader('Playlisty'), SkeletonCardRail(height: 214, cardWidth: 150)],
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.value,
    required this.onSeeAll,
    required this.loading,
    required this.builder,
  });

  final String title;
  final AsyncValue<List<SearchResultItem>> value;
  final VoidCallback onSeeAll;
  final Widget loading;
  final Widget Function(List<SearchResultItem> items) builder;

  @override
  Widget build(BuildContext context) {
    if (value.hasValue && value.value!.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title, onSeeAll: value.hasValue ? onSeeAll : null),
        value.when(
          data: builder,
          loading: () => loading,
          error: (error, stack) => ErrorState(compact: true, message: _errorMessage(error)),
        ),
      ],
    );
  }
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
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.item});
  final SearchResultItem item;

  @override
  Widget build(BuildContext context) => MediaCard(
        shape: MediaCardShape.circle,
        placeholderIcon: Symbols.person_rounded,
        title: item.title,
        subtitle: 'Interpret',
        imageUrl: item.imageUrl,
        artworkKey: (releaseId: null, artistId: item.id),
        onTap: () => context.push('/artists/${item.id}'),
        onLongPress: () => showArtistActions(context, id: item.id, name: item.title, imageUrl: item.imageUrl),
      );
}

/// Album bez obrázku v odpovědi hledání si ho dotáhne samo (Release detail
/// endpoint obal doplní z Deezeru) -- stejně jako skladby přes
/// `recordingArtworkProvider`.
class _ReleaseCard extends ConsumerWidget {
  const _ReleaseCard({required this.item});
  final SearchResultItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = (item.subtitle ?? '').split(' · ');
    final typeLabel = _releaseTypeLabels[parts.first] ?? parts.first;
    return MediaCard(
      title: item.title,
      subtitle: [typeLabel, ...parts.skip(1)].where((p) => p.isNotEmpty).join(' · '),
      imageUrl: item.imageUrl,
      artworkKey: (releaseId: item.id, artistId: item.artistId),
      onTap: () => context.push('/releases/${item.id}'),
      onLongPress: () => showCollectionActions(
        context,
        kind: CollectionKind.album,
        id: item.id,
        title: item.title,
        subtitle: item.subtitle,
        imageUrl: item.imageUrl,
      ),
    );
  }
}

/// Jeden typ výsledků přes celou obrazovku (větší limit).
class _FilteredResults extends ConsumerWidget {
  const _FilteredResults({super.key, required this.query, required this.filter});
  final String query;
  final SearchFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (query: query, type: _entityTypeFor[filter]!, limit: 40);
    final results = ref.watch(searchSectionProvider(key));
    return results.when(
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: Symbols.search_off_rounded,
            message: 'Žádné výsledky typu „${_filterLabels[filter]!.toLowerCase()}“ pro „$query“.',
          );
        }
        switch (filter) {
          case SearchFilter.tracks:
            final List<RecordingModel> recordings = items.map((i) => i.toRecordingModel()).toList();
            return ListView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.lg + navBottomInset(context)),
              itemCount: recordings.length,
              itemBuilder: (context, index) => TrackTile(
                recording: recordings[index],
                queueRecordings: recordings,
                sourceLabel: _searchSourceLabel,
              ),
            );
          case SearchFilter.artists:
          case SearchFilter.albums:
          case SearchFilter.all:
            final columns = (MediaQuery.sizeOf(context).width / 170).floor().clamp(2, 8);
            return GridView.builder(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm + navBottomInset(context)),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: filter == SearchFilter.artists ? 0.8 : 0.72,
                crossAxisSpacing: AppSpacing.sm,
                mainAxisSpacing: AppSpacing.sm,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) =>
                  filter == SearchFilter.artists ? _ArtistCard(item: items[index]) : _ReleaseCard(item: items[index]),
            );
        }
      },
      loading: () => filter == SearchFilter.tracks ? const LoadingState() : const LoadingState(count: 6),
      error: (error, stack) => ErrorState(
        message: _errorMessage(error),
        onRetry: () => ref.invalidate(searchSectionProvider(key)),
      ),
    );
  }
}


/// Žánry a styly k dotazu ("blues" -> Blues, Chicago Blues, Delta Blues...).
final searchTagsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, query) async {
  final json = await ref.watch(apiClientProvider).getJson('/browse/search-tags', query: {'q': query});
  return (json['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
});

/// Hledat › Vše: řada tlačítek žánrů a stylů (stejná jako "Prozkoumej své
/// styly" na Domů) -- kategorie otevře Procházet, styl stránku stylu.
class _GenreChips extends ConsumerWidget {
  const _GenreChips({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(searchTagsProvider(query)).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.xs),
          itemBuilder: (context, i) {
            final item = items[i];
            final isCategory = item['kind'] == 'category';
            return ActionChip(
              avatar: Icon(isCategory ? Symbols.category_rounded : Symbols.sell_rounded, size: 18),
              label: Text(item['title'] as String),
              onPressed: () => context.push(
                isCategory ? '/browse/${item['id']}' : tagRoute(item['tag'] as String),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Filmy, seriály a hry (Wikidata) k dotazu -- soundtrack se otevře na stránce díla.
final worksSearchProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, query) async {
  final json = await ref.watch(apiClientProvider).getJson('/works/search', query: {'q': query});
  return (json['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
});

class _WorksSection extends ConsumerWidget {
  const _WorksSection({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(worksSearchProvider(query)).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Filmy, seriály a hry'),
        SizedBox(
          height: 200,
          child: ListView.separated(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, i) => WorkCover(work: items[i]),
          ),
        ),
      ],
    );
  }
}

final soundcloudSearchProvider = FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, query) async {
  final json = await ref.watch(apiClientProvider).getJson('/catalog/soundcloud/search', query: {'q': query});
  return (json['items'] as List<dynamic>? ?? const [])
      .map((e) => RecordingModel.fromJson(e as Map<String, dynamic>))
      .toList();
});

/// Hledat › Vše › SoundCloud -- dema, remixy, živáky a věci, které jinde
/// nejsou. Vlastní sekce na konci výsledků; prázdná/nedostupná se skryje
/// (SoundCloud je doplněk, nemá shazovat celé hledání).
class _SoundcloudSection extends ConsumerStatefulWidget {
  const _SoundcloudSection({required this.query});
  final String query;

  @override
  ConsumerState<_SoundcloudSection> createState() => _SoundcloudSectionState();
}

class _SoundcloudSectionState extends ConsumerState<_SoundcloudSection> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(soundcloudSearchProvider(widget.query));
    return results.when(
      data: (items) => items.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  'SoundCloud',
                  onSeeAll: items.length > 5 && !_all ? () => setState(() => _all = true) : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  child: Column(
                    children: [
                      for (final r in _all ? items : items.take(5))
                        TrackTile(recording: r, queueRecordings: items, sourceLabel: 'SoundCloud'),
                    ],
                  ),
                ),
              ],
            ),
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SectionHeader('SoundCloud'), SkeletonTrackList(count: 3)],
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
