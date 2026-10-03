import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/home_repository.dart' show HomePlaylistCard;
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
import '../../widgets/track_tile.dart';
import '../library/playlist_detail_screen.dart' show playlistDetailProvider;
import '../release/release_screen.dart' show releaseProvider, releaseTracksProvider;

/// Procházet › Herní soundtracky / Filmy a seriály (app/games.py,
/// app/movies.py): velké obrázky nahoře, mixy, série (jako interpret --
/// hudba ze všech dílů), řady, skladatelé. `base` = "games" / "movies".
final soundtrackApiProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, path) {
  return ref.watch(apiClientProvider).getJson(path);
});

List<Map<String, dynamic>> _list(Object? value) => (value as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

String _composerLine(Map<String, dynamic> game) {
  final composers = (game['composers'] as List<dynamic>? ?? const []).cast<String>();
  return [if (composers.isNotEmpty) composers.take(2).join(', '), if (game['year'] != null) '${game['year']}'].join(' · ');
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
        error: (e, _) =>
            ErrorState(message: 'Stránku se nepodařilo načíst.', error: e, onRetry: () => ref.invalidate(soundtrackApiProvider('/$base'))),
        data: (data) {
          final heroes = _list(data['heroes']);
          final mixes = _list(data['mixes']).map(HomePlaylistCard.fromJson).toList();
          final series = _list(data['series']);
          final composers = _list(data['composers']);
          void seeAll(String list) => context.push('/$base/list/$list');
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _HeroCarousel(games: heroes, base: base, title: title)),
              if (mixes.isNotEmpty) ...[
                SliverToBoxAdapter(child: SectionHeader('Mixy', onSeeAll: mixes.length > 2 ? () => seeAll('mixes') : null)),
                SliverToBoxAdapter(
                  child: _Rail(height: 214, children: [
                    for (final m in mixes) PlaylistCardView(card: m, onTap: () => context.push('/playlists/${m.id}')),
                  ]),
                ),
              ],
              if (series.isNotEmpty) ...[
                SliverToBoxAdapter(child: SectionHeader('Série', onSeeAll: series.length > 1 ? () => seeAll('series') : null)),
                SliverToBoxAdapter(
                  child: _Rail(height: 140, children: [
                    for (final s in series) _SeriesTile(series: s, base: base, unit: data['seriesUnit'] as String? ?? ''),
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
                    child: _Rail(height: 250, children: [for (final g in _list(row['games'])) GameCover(game: g, base: base)]),
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
  const _HeroCarousel({required this.games, required this.base, required this.title});
  final List<Map<String, dynamic>> games;
  final String base;
  final String title;

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
      final fraction = width >= 1100 ? 0.45 : (width >= 700 ? 0.65 : 0.9);
      if (_controller == null || fraction != _fraction) {
        _controller?.dispose();
        _fraction = fraction;
        _controller = PageController(viewportFraction: fraction, initialPage: n * (_loops ~/ 2) + _page);
        _restartTimer();
      }
      final height = (width * fraction * 0.56).clamp(190.0, 360.0);
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
                      onTap: () => context.push('/${widget.base}/${g['slug']}'),
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
                                        Text(_composerLine(g), maxLines: 1, style: const TextStyle(color: Colors.white70)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  GlassIconButton(
                                    icon: Symbols.play_arrow_rounded,
                                    tooltip: 'Soundtrack',
                                    onPressed: () => context.push('/${widget.base}/${g['slug']}'),
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

class _Veil extends StatelessWidget {
  const _Veil();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x66000000), Color(0x00000000), Color(0xDD000000)],
            stops: [0, 0.4, 1],
          ),
        ),
      );
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
      onTap: () => context.push('/$base/series/${series['id']}'),
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
      onTap: () => context.push('/$base/${game['slug']}'),
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
            Text(game['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
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
        error: (e, _) => ErrorState(message: 'Nepodařilo se načíst.', error: e, onRetry: () => ref.invalidate(soundtrackApiProvider('/$base'))),
        data: (data) {
          final unit = data['seriesUnit'] as String? ?? '';
          final (List<Map<String, dynamic>> items, double extent, double ratio, Widget Function(Map<String, dynamic>) build) =
              switch (listId) {
            'series' => (_list(data['series']), 260, 230 / 140, (s) => _SeriesTile(series: s, base: base, unit: unit, width: double.infinity)),
            'composers' => (_list(data['composers']), 150, 0.72, (a) => _ComposerCard(artist: a, width: double.infinity)),
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
            padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xl + navBottomInset(context)),
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

/// Stránka díla: velký obrázek, soundtrack se skladbami (Přehrát /
/// Zamíchat), rádia (GTA), další díly série.
class GameScreen extends ConsumerWidget {
  const GameScreen({super.key, required this.slug, this.base = 'games'});
  final String slug;
  final String base;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final game = ref.watch(soundtrackApiProvider('/$base/$slug'));
    final theme = Theme.of(context);
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: game.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(message: 'Nepodařilo se načíst.', error: e, onRetry: () => ref.invalidate(soundtrackApiProvider('/$base/$slug'))),
        data: (g) {
          final others = _list(g['seriesGames']);
          final stations = _list(g['stations']).map(HomePlaylistCard.fromJson).toList();
          final albums = _list(g['albums']);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _GameHeader(game: g)),
              if (g['series'] != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ActionChip(
                        avatar: const Icon(Symbols.collections_bookmark_rounded, size: 18),
                        label: Text('Série: ${g['seriesTitle']}'),
                        onPressed: () => context.push('/$base/series/${g['series']}'),
                      ),
                    ),
                  ),
                ),
              if (stations.isNotEmpty) ...[
                SliverToBoxAdapter(child: SectionHeader(g['stationsTitle'] as String? ?? 'Rádia')),
                SliverToBoxAdapter(
                  child: _Rail(height: 214, children: [
                    for (final s in stations) PlaylistCardView(card: s, onTap: () => context.push('/playlists/${s.id}')),
                  ]),
                ),
              ],
              if (albums.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(
                      stations.isNotEmpty
                          ? 'Hudba je v rádiích výše.'
                          : 'Soundtrack zatím na streamovacích službách není (nebo jen jako covery, ty nepouštíme).',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                for (final album in albums)
                  SliverToBoxAdapter(
                    child: _AlbumSection(
                      albumId: album['id'] as String,
                      kind: album['kind'] as String? ?? 'score',
                      sourceLabel: g['title'] as String,
                    ),
                  ),
              if (others.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Další díly série')),
                SliverToBoxAdapter(child: _Rail(height: 250, children: [for (final o in others) GameCover(game: o, base: base)])),
              ],
              SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + navBottomInset(context))),
            ],
          );
        },
      ),
    );
  }
}

class _GameHeader extends StatelessWidget {
  const _GameHeader({required this.game, this.subtitle});
  final Map<String, dynamic> game;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return SizedBox(
      height: 280 + top,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ArtworkImage(url: (game['hero'] ?? game['image']) as String?, icon: Symbols.movie_rounded),
          const _Veil(),
          Positioned(
            top: top + AppSpacing.xs,
            left: AppSpacing.sm,
            child: IconButton(
              tooltip: 'Zpět',
              icon: const Icon(Symbols.arrow_back_rounded, color: Colors.white),
              onPressed: () => context.pop(),
            ),
          ),
          Positioned(
            left: AppSpacing.md,
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  game['title'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(subtitle ?? _composerLine(game), style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Stránka série -- jako interpret: Přehrát / Zamíchat celou sérii, nejlepší
/// skladby, díly jako diskografie (klepnutí = soundtrack toho dílu).
class GameSeriesScreen extends ConsumerWidget {
  const GameSeriesScreen({super.key, required this.seriesId, this.base = 'games'});
  final String seriesId;
  final String base;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = '/$base/series/$seriesId';
    final series = ref.watch(soundtrackApiProvider(path));
    final theme = Theme.of(context);
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: series.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(message: 'Sérii se nepodařilo načíst.', error: e, onRetry: () => ref.invalidate(soundtrackApiProvider(path))),
        data: (s) {
          final games = _list(s['games']);
          final latest = games.isEmpty ? null : games.last;
          final playlistId = s['playlistId'] as String?;
          final playlist = playlistId == null ? null : ref.watch(playlistDetailProvider(playlistId)).valueOrNull;
          final tracks = playlist?.items ?? const [];
          final stations = _list(s['stations']).map(HomePlaylistCard.fromJson).toList();
          final withOst = games.where((g) => g['albumId'] != null).length;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _GameHeader(
                  game: {'title': s['title'], 'hero': latest?['hero']},
                  subtitle: '${games.length} ${s['unit'] ?? ''} · $withOst se soundtrackem',
                ),
              ),
              if (tracks.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                    child: QueueActionBar(tracks: tracks, sourceLabel: s['title'] as String),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SectionHeader('Skladby ze všech dílů', onSeeAll: () => context.push('/playlists/$playlistId')),
                ),
                SliverList.builder(
                  itemCount: tracks.length.clamp(0, 8),
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    child: TrackTile(recording: tracks[i], queueRecordings: tracks, sourceLabel: s['title'] as String),
                  ),
                ),
              ],
              if (stations.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Rádia')),
                SliverToBoxAdapter(
                  child: _Rail(height: 214, children: [
                    for (final st in stations) PlaylistCardView(card: st, onTap: () => context.push('/playlists/${st.id}')),
                  ]),
                ),
              ],
              const SliverToBoxAdapter(child: SectionHeader('Díly')),
              SliverList.builder(
                itemCount: games.length,
                itemBuilder: (context, i) {
                  final g = games[games.length - 1 - i]; // nejnovější nahoře, jako diskografie
                  final has = g['albumId'] != null;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xxs),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: SizedBox(
                        width: 48,
                        height: 72,
                        child: ArtworkImage(url: (g['cover'] ?? g['hero']) as String?, icon: Symbols.movie_rounded),
                      ),
                    ),
                    title: Text(g['title'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      has ? _composerLine(g) : '${g['year']} · soundtrack není ke streamování',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: Icon(has ? Symbols.play_circle_rounded : Symbols.chevron_right_rounded,
                        color: has ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
                    onTap: () => context.push('/$base/${g['slug']}'),
                  );
                },
              ),
              SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + navBottomInset(context))),
            ],
          );
        },
      ),
    );
  }
}


/// Jedno album díla (Original Score / Soundtrack s písněmi): název, Přehrát
/// / Zamíchat a skladby.
class _AlbumSection extends ConsumerWidget {
  const _AlbumSection({required this.albumId, required this.kind, required this.sourceLabel});
  final String albumId;
  final String kind;
  final String sourceLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(releaseProvider(albumId)).valueOrNull;
    final tracks = ref.watch(releaseTracksProvider(albumId));
    final list = tracks.valueOrNull ?? const [];
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          kind == 'songs' ? 'Soundtrack (písně)' : 'Original Score',
          onSeeAll: () => context.push('/releases/$albumId'),
        ),
        if (release != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
            child: Text(release.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        if (list.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: QueueActionBar(tracks: list, sourceLabel: sourceLabel, albumArtUrl: release?.coverImageUrl),
          ),
        if (tracks.isLoading) const LoadingState(count: 5),
        for (var i = 0; i < list.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: TrackTile(
              recording: list[i],
              leadingIndex: list[i].trackNumber ?? i + 1,
              albumArtUrl: release?.coverImageUrl,
              queueRecordings: list,
              sourceLabel: sourceLabel,
            ),
          ),
      ],
    );
  }
}
