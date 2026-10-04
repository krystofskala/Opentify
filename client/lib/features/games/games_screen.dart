import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/home_repository.dart' show HomeAlbumCard, HomePlaylistCard;
import '../../models/recording_model.dart';
import '../../routing/branches.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/queue_action_bar.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/track_tile.dart';

/// Procházet › Herní soundtracky / Filmy a seriály (app/games.py,
/// app/movies.py): velké obrázky nahoře, mixy, série (jako interpret --
/// hudba ze všech dílů), řady, skladatelé. `base` = "games" / "movies".
final soundtrackApiProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, path) {
  return ref.watch(apiClientProvider).getJson(path);
});

List<Map<String, dynamic>> _list(Object? value) => (value as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

String _composerLine(Map<String, dynamic> game) {
  final composers = (game['composers'] as List<dynamic>? ?? const []).cast<String>();
  return [if (composers.isNotEmpty) composers.take(2).join(', '), if (game['year'] != null) '${game['year']}']
      .join(' · ');
}

/// Dílo = jeho soundtrack (album). Bez alba (GTA -- jen rádia) franšíza.
void _openWork(BuildContext context, Map<String, dynamic> work) {
  final albumId = work['albumId'] as String?;
  final series = work['series'] as String?;
  if (albumId != null) {
    context.push('/releases/$albumId');
  } else if (series != null) {
    context.push('/franchise/$series');
  }
}

class GamesScreen extends ConsumerWidget {
  const GamesScreen({super.key, this.base = 'games', this.title = 'Herní soundtracky'});
  final String base;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(soundtrackApiProvider('/$base'));
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: page.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
            message: 'Stránku se nepodařilo načíst.',
            error: e,
            onRetry: () => ref.invalidate(soundtrackApiProvider('/$base'))),
        data: (data) {
          final heroes = _list(data['heroes']);
          final mixes = _list(data['mixes']).map(HomePlaylistCard.fromJson).toList();
          final series = _list(data['series']);
          final composers = _list(data['composers']);
          void seeAll(String list) => context.push('/$base/list/$list');
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _HeroCarousel(games: heroes, base: base, title: title, poster: data['poster'] == true)),
              if (mixes.isNotEmpty) ...[
                SliverToBoxAdapter(
                    child: SectionHeader('Mixy', onSeeAll: mixes.length > 2 ? () => seeAll('mixes') : null)),
                SliverToBoxAdapter(
                  child: _Rail(height: 214, children: [
                    for (final m in mixes) PlaylistCardView(card: m, onTap: () => context.push('/playlists/${m.id}')),
                  ]),
                ),
              ],
              if (series.isNotEmpty) ...[
                SliverToBoxAdapter(
                    child: SectionHeader('Série', onSeeAll: series.length > 1 ? () => seeAll('series') : null)),
                SliverToBoxAdapter(
                  child: _Rail(height: 140, children: [
                    for (final s in series)
                      _SeriesTile(series: s, base: base, unit: data['seriesUnit'] as String? ?? ''),
                  ]),
                ),
              ],
              for (final row in _list(data['rows']))
                if (_list(row['games']).isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SectionHeader(
                      row['title'] as String,
                      onSeeAll: _list(row['games']).length > 2 ? () => seeAll(row['id'] as String) : null,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _Rail(
                        height: 250, children: [for (final g in _list(row['games'])) GameCover(game: g, base: base)]),
                  ),
                ],
              if (composers.isNotEmpty) ...[
                SliverToBoxAdapter(child: SectionHeader('Skladatelé', onSeeAll: () => seeAll('composers'))),
                SliverToBoxAdapter(
                  child: _Rail(height: 190, children: [for (final a in composers) _ComposerCard(artist: a)]),
                ),
              ],
              SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + navBottomInset(context))),
            ],
          );
        },
      ),
    );
  }
}

class _ComposerCard extends StatelessWidget {
  const _ComposerCard({required this.artist, this.width = 130});
  final Map<String, dynamic> artist;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: MediaCard(
          title: artist['name'] as String? ?? '',
          imageUrl: (artist['images'] as List<dynamic>? ?? const []).cast<String>().firstOrNull,
          shape: MediaCardShape.circle,
          placeholderIcon: Symbols.person_rounded,
          onTap: () => context.push('/artists/${artist['id']}'),
        ),
      );
}

/// Velké obrázky děl jako zaoblené karty -- samy přetáčí (6 s), jdou táhnout
/// prstem i myší, vedlejší karty vykukují. Výběr a pořadí se mění denně.
class _HeroCarousel extends StatefulWidget {
  const _HeroCarousel({required this.games, required this.base, required this.title, this.poster = false});
  final List<Map<String, dynamic>> games;
  final String base;
  final String title;

  /// Filmy: plakáty na výšku (Apple) místo širokých obrázků.
  final bool poster;

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  static const _loops = 1000; // "nekonečné" točení dokola
  PageController? _controller;
  double _fraction = 0;
  int _page = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      final c = _controller;
      if (c == null || !c.hasClients || !mounted) return;
      // Omezení pohybu: karusel se sám neotáčí, jen tažením.
      if (MediaQuery.disableAnimationsOf(context)) return;
      c.nextPage(duration: const Duration(milliseconds: 650), curve: Curves.easeInOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final theme = Theme.of(context);
    final n = widget.games.length;
    final header = Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.xs, top + AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
      child: Row(
        children: [
          if (context.canPop())
            IconButton(tooltip: 'Zpět', icon: const Icon(Symbols.arrow_back_rounded), onPressed: () => context.pop())
          else
            const SizedBox(width: AppSpacing.sm),
          Text(widget.title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
    if (n == 0) return header;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      // Na telefonu skoro celá šířka, na širokém okně víc karet vedle sebe.
      final fraction = widget.poster
          ? (width >= 1100 ? 0.18 : (width >= 700 ? 0.3 : 0.62))
          : (width >= 1100 ? 0.45 : (width >= 700 ? 0.65 : 0.9));
      if (_controller == null || fraction != _fraction) {
        _controller?.dispose();
        _fraction = fraction;
        _controller = PageController(viewportFraction: fraction, initialPage: n * (_loops ~/ 2) + _page);
        _restartTimer();
      }
      final height = widget.poster
          ? (width * fraction * 1.45).clamp(260.0, 460.0)
          : (width * fraction * 0.56).clamp(190.0, 360.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(
            height: height,
            child: ScrollConfiguration(
              // I myší / trackpadem (PC) -- jinak jde táhnout jen prstem.
              behavior: ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
              child: PageView.builder(
                controller: _controller,
                itemCount: n * _loops,
                onPageChanged: (i) {
                  setState(() => _page = i % n);
                  _restartTimer();
                },
                itemBuilder: (context, i) {
                  final g = widget.games[i % n];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    child: GestureDetector(
                      onTap: () => _openWork(context, g),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.lg),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ArtworkImage(url: g['hero'] as String?, icon: Symbols.movie_rounded),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Color(0x00000000), Color(0xCC000000)],
                                  stops: [0.45, 1],
                                ),
                              ),
                            ),
                            Positioned(
                              left: AppSpacing.md,
                              right: AppSpacing.md,
                              bottom: AppSpacing.md,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          g['title'] as String,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleLarge
                                              ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                                        ),
                                        Text(_composerLine(g),
                                            maxLines: 1, style: const TextStyle(color: Colors.white70)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  GlassIconButton(
                                    icon: Symbols.play_arrow_rounded,
                                    tooltip: 'Soundtrack',
                                    onPressed: () => _openWork(context, g),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < n; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: i == _page ? 0.9 : 0.3),
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                ),
            ],
          ),
        ],
      );
    });
  }
}

class _SeriesTile extends StatelessWidget {
  const _SeriesTile({required this.series, required this.base, required this.unit, this.width = 230});
  final Map<String, dynamic> series;
  final String base;
  final String unit;
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/franchise/${series['id']}'),
      child: SizedBox(
        width: width,
        height: 140,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ArtworkImage(url: series['image'] as String?, icon: Symbols.movie_rounded),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
              ),
              Positioned(
                left: AppSpacing.sm,
                right: AppSpacing.sm,
                bottom: AppSpacing.sm,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(series['title'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                    Text('${series['count']} $unit', style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Obal díla na výšku + název a rok.
class GameCover extends StatelessWidget {
  const GameCover({super.key, required this.game, this.base = 'games', this.width = 140});
  final Map<String, dynamic> game;
  final String base;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => _openWork(context, game),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ArtworkImage(url: (game['cover'] ?? game['hero']) as String?, icon: Symbols.movie_rounded),
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(game['title'] as String,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            Text(
              game['albumId'] == null ? '${game['year']} · bez soundtracku' : '${game['year']}',
              maxLines: 1,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
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

/// "Zobrazit vše" u řady (hry, série, mixy, skladatelé) -- mřížka.
class GamesListScreen extends ConsumerWidget {
  const GamesListScreen({super.key, required this.base, required this.listId});
  final String base;
  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(soundtrackApiProvider('/$base'));
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      appBar: SectionAppBar(_title(page.valueOrNull)),
      body: page.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
            message: 'Nepodařilo se načíst.', error: e, onRetry: () => ref.invalidate(soundtrackApiProvider('/$base'))),
        data: (data) {
          final unit = data['seriesUnit'] as String? ?? '';
          final (
            List<Map<String, dynamic>> items,
            double extent,
            double ratio,
            Widget Function(Map<String, dynamic>) build
          ) = switch (listId) {
            'series' => (
                _list(data['series']),
                260,
                230 / 140,
                (s) => _SeriesTile(series: s, base: base, unit: unit, width: double.infinity)
              ),
            'composers' => (
                _list(data['composers']),
                150,
                0.72,
                (a) => _ComposerCard(artist: a, width: double.infinity)
              ),
            'mixes' => (
                _list(data['mixes']),
                180,
                0.72,
                (m) {
                  final card = HomePlaylistCard.fromJson(m);
                  return PlaylistCardView(card: card, onTap: () => context.push('/playlists/${card.id}'));
                },
              ),
            _ => (
                _list(_list(data['rows']).where((r) => r['id'] == listId).firstOrNull?['games']),
                160,
                0.5,
                (g) => GameCover(game: g, base: base, width: double.infinity),
              ),
          };
          return GridView.builder(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xl + navBottomInset(context)),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: extent,
              childAspectRatio: ratio,
              crossAxisSpacing: AppSpacing.sm,
              mainAxisSpacing: AppSpacing.sm,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => build(items[i]),
          );
        },
      ),
    );
  }

  String _title(Map<String, dynamic>? data) => switch (listId) {
        'series' => 'Série',
        'composers' => 'Skladatelé',
        'mixes' => 'Mixy',
        _ => (_list(data?['rows']).where((r) => r['id'] == listId).firstOrNull?['title'] as String?) ?? '',
      };
}

final franchiseProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) {
  return ref.watch(apiClientProvider).getJson('/browse/franchise/$id');
});

String _yearRange(List<int> years) {
  if (years.isEmpty) return '';
  final lo = years.reduce((a, b) => a < b ? a : b);
  final hi = years.reduce((a, b) => a > b ? a : b);
  return lo == hi ? '$lo' : '$lo–$hi';
}

class FranchiseScreen extends ConsumerWidget {
  const FranchiseScreen({super.key, required this.franchiseId});
  final String franchiseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(franchiseProvider(franchiseId));
    return page.when(
      loading: () => const Scaffold(bottomNavigationBar: ShellBarSpace(), body: LoadingState()),
      error: (e, _) => Scaffold(
        bottomNavigationBar: const ShellBarSpace(),
        body: ErrorState(
            message: 'Nepodařilo se načíst.', error: e, onRetry: () => ref.invalidate(franchiseProvider(franchiseId))),
      ),
      data: (f) {
        final albums = _list(f['albums']).map(HomeAlbumCard.fromJson).toList();
        final stations = _list(f['stations']).map(HomePlaylistCard.fromJson).toList();
        final composers = _list(f['composers']);
        final playlistId = f['playlistId'] as String?;
        final List<RecordingModel> tracks = playlistId == null
            ? const []
            : ref.watch(playlistDetailProvider(playlistId)).valueOrNull?.items ?? const [];
        final years = (f['years'] as List<dynamic>? ?? const []).cast<int>();
        final title = f['title'] as String? ?? '';
        final isGames = f['kind'] == 'games';
        return ScreenAccent(
          imageUrl: f['cover'] as String?,
          builder: (context, accent) => Scaffold(
            bottomNavigationBar: const ShellBarSpace(),
            body: CustomScrollView(
              slivers: [
                DetailHeroAppBar(
                  title: title,
                  imageUrl: f['cover'] as String?,
                  bannerImageUrl: f['image'] as String?,
                  accent: accent,
                  eyebrow: isGames ? 'Herní série' : 'Franšíza',
                  eyebrowIcon: isGames ? Symbols.sports_esports_rounded : Symbols.movie_rounded,
                  placeholderIcon: Symbols.movie_rounded,
                  meta: [
                    if (albums.isNotEmpty) HeroMetaItem(Symbols.album_rounded, '${albums.length} soundtracků'),
                    if (stations.isNotEmpty) HeroMetaItem(Symbols.radio_rounded, '${stations.length} rádií'),
                    if (years.isNotEmpty) HeroMetaItem(Symbols.calendar_today_rounded, _yearRange(years)),
                  ],
                ),
                ...detailContentSlivers(context, [
                  if (tracks.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                        child: QueueActionBar(tracks: tracks, sourceLabel: title),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SectionHeader('Oblíbené skladby', onSeeAll: () => context.push('/playlists/$playlistId')),
                    ),
                    SliverList.builder(
                      itemCount: tracks.length.clamp(0, 5),
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                        child: TrackTile(
                            recording: tracks[i], leadingIndex: i + 1, queueRecordings: tracks, sourceLabel: title),
                      ),
                    ),
                  ],
                  // Rádia po hrách (GTA: 49 stanic v pěti hrách) -- každá řada
                  // se "Zobrazit vše".
                  for (final group in _byGame(stations)) ...[
                    SliverToBoxAdapter(
                      child: SectionHeader(
                        group.$1 == null ? 'Rádia' : 'Rádia · ${group.$1}',
                        onSeeAll: group.$2.length > 2 ? () => _showStations(context, group.$1 ?? 'Rádia', group.$2) : null,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _Rail(height: 214, children: [
                        for (final s in group.$2)
                          PlaylistCardView(card: s, onTap: () => context.push('/playlists/${s.id}')),
                      ]),
                    ),
                  ],
                  if (albums.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SectionHeader('Soundtracky')),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 180,
                          childAspectRatio: 0.74,
                          crossAxisSpacing: AppSpacing.sm,
                          mainAxisSpacing: AppSpacing.sm,
                        ),
                        itemCount: albums.length,
                        itemBuilder: (context, i) {
                          final a = albums[i];
                          final year = (a.releaseDate ?? '').length >= 4 ? a.releaseDate!.substring(0, 4) : null;
                          return MediaCard(
                            title: a.title,
                            subtitle: [year, a.artistName].whereType<String>().join(' · '),
                            imageUrl: a.images.firstOrNull,
                            artworkKey: (releaseId: a.id, artistId: null),
                            onTap: () => context.push('/releases/${a.id}'),
                          );
                        },
                      ),
                    ),
                  ],
                  if (composers.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SectionHeader('Hudbu složili')),
                    SliverToBoxAdapter(
                      child: _Rail(height: 190, children: [
                        for (final a in composers)
                          SizedBox(
                            width: 130,
                            child: MediaCard(
                              title: a['name'] as String? ?? '',
                              imageUrl: (a['images'] as List<dynamic>? ?? const []).cast<String>().firstOrNull,
                              shape: MediaCardShape.circle,
                              placeholderIcon: Symbols.person_rounded,
                              onTap: () => context.push('/artists/${a['id']}'),
                            ),
                          ),
                      ]),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Dílo ve výsledcích hledání -- vede na franšízu, jinak rovnou na album.
class WorkCover extends StatelessWidget {
  const WorkCover({super.key, required this.work, this.width = 140});
  final Map<String, dynamic> work;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final franchise = work['franchise'] as String?;
    final albumId = work['albumId'] as String?;
    return GestureDetector(
      onTap: () => context.push(franchise != null ? '/franchise/$franchise' : '/releases/$albumId'),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: AspectRatio(
                aspectRatio: 1,
                child: ArtworkImage(url: work['cover'] as String?, icon: Symbols.movie_rounded),
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(work['title'] as String,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            Text(
              [
                if ((work['year'] ?? 0) != 0) '${work['year']}',
                if (work['franchiseTitle'] != null) work['franchiseTitle'] as String,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Franšíza na stránce soundtracků (dlaždice s obrázkem).
class FranchiseTile extends StatelessWidget {
  const FranchiseTile({super.key, required this.franchise, this.width = 230});
  final Map<String, dynamic> franchise;
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/franchise/${franchise['id']}'),
      child: SizedBox(
        width: width,
        height: 140,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ArtworkImage(url: franchise['image'] as String?, icon: Symbols.movie_rounded),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
              ),
              Positioned(
                left: AppSpacing.sm,
                right: AppSpacing.sm,
                bottom: AppSpacing.sm,
                child: Text(
                  franchise['title'] as String? ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Rádia seskupená podle hry (popis playlistu = název hry), nejnovější hra napřed.
List<(String?, List<HomePlaylistCard>)> _byGame(List<HomePlaylistCard> stations) {
  final groups = <String?, List<HomePlaylistCard>>{};
  for (final s in stations) {
    groups.putIfAbsent(s.description, () => []).add(s);
  }
  return [for (final e in groups.entries) (e.key, e.value)];
}

void _showStations(BuildContext context, String title, List<HomePlaylistCard> stations) {
  showGlassSheet<void>(
    context,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => GlassSheet(
        expand: true,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverToBoxAdapter(child: SectionHeader(title)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  childAspectRatio: 0.72,
                  crossAxisSpacing: AppSpacing.sm,
                  mainAxisSpacing: AppSpacing.sm,
                ),
                itemCount: stations.length,
                itemBuilder: (context, i) => PlaylistCardView(
                  card: stations[i],
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.push('/playlists/${stations[i].id}');
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
