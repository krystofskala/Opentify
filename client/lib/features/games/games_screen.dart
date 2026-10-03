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
import '../../widgets/state_views.dart';

/// Procházet › Herní soundtracky (app/games.py): velké obrázky her nahoře,
/// herní mixy, série (jako "interpret" -- hudba ze všech dílů), řady her,
/// skladatelé.
final gamesPageProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  return ref.watch(apiClientProvider).getJson('/games');
});

final gameProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, slug) {
  return ref.watch(apiClientProvider).getJson('/games/$slug');
});

final gameSeriesProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) {
  return ref.watch(apiClientProvider).getJson('/games/series/$id');
});

List<Map<String, dynamic>> _list(Object? value) => (value as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

String _composerLine(Map<String, dynamic> game) {
  final composers = (game['composers'] as List<dynamic>? ?? const []).cast<String>();
  return [if (composers.isNotEmpty) composers.take(2).join(', '), if (game['year'] != null) '${game['year']}']
      .join(' · ');
}

class GamesScreen extends ConsumerWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(gamesPageProvider);
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: page.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
            message: 'Hry se nepodařilo načíst.', error: e, onRetry: () => ref.invalidate(gamesPageProvider)),
        data: (data) {
          final heroes = _list(data['heroes']);
          final mixes = _list(data['mixes']).map(HomePlaylistCard.fromJson).toList();
          final series = _list(data['series']);
          final composers = _list(data['composers']);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _HeroCarousel(games: heroes)),
              if (mixes.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Herní mixy')),
                SliverToBoxAdapter(
                  child: _Rail(height: 214, children: [
                    for (final m in mixes) PlaylistCardView(card: m, onTap: () => context.push('/playlists/${m.id}')),
                  ]),
                ),
              ],
              if (series.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Série')),
                SliverToBoxAdapter(
                  child: _Rail(height: 140, children: [for (final s in series) _SeriesTile(series: s)]),
                ),
              ],
              for (final row in _list(data['rows']))
                if (_list(row['games']).isNotEmpty) ...[
                  SliverToBoxAdapter(child: SectionHeader(row['title'] as String)),
                  SliverToBoxAdapter(
                    child: _Rail(height: 250, children: [for (final g in _list(row['games'])) GameCover(game: g)]),
                  ),
                ],
              if (composers.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Skladatelé')),
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
              SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + navBottomInset(context))),
            ],
          );
        },
      ),
    );
  }
}

/// Velké obrázky her přes celou šířku -- swipe mezi nimi, klepnutí otevře hru.
class _HeroCarousel extends StatefulWidget {
  const _HeroCarousel({required this.games});
  final List<Map<String, dynamic>> games;

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final height = 300.0 + top;
    if (widget.games.isEmpty) return SizedBox(height: top + 56);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.games.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) {
              final g = widget.games[i];
              return GestureDetector(
                onTap: () => context.push('/games/${g['slug']}'),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ArtworkImage(url: g['hero'] as String?, icon: Symbols.sports_esports_rounded),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), Color(0x00000000), Color(0xDD000000)],
                          stops: [0, 0.4, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      left: AppSpacing.md,
                      right: AppSpacing.md,
                      bottom: AppSpacing.lg,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            g['title'] as String,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: AppSpacing.xxs),
                          Text(_composerLine(g), style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: AppSpacing.sm),
                          GlassButton(
                            label: 'Soundtrack',
                            icon: Symbols.play_arrow_rounded,
                            style: GlassButtonStyle.prominent,
                            onPressed: g['albumId'] == null ? null : () => context.push('/releases/${g['albumId']}'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Positioned(
            top: top + AppSpacing.xs,
            left: AppSpacing.sm,
            right: AppSpacing.md,
            child: Row(
              children: [
                if (context.canPop())
                  IconButton(
                    tooltip: 'Zpět',
                    icon: const Icon(Symbols.arrow_back_rounded, color: Colors.white),
                    onPressed: () => context.pop(),
                  ),
                Text('Herní soundtracky',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          Positioned(
            bottom: AppSpacing.xs,
            right: AppSpacing.md,
            child: Row(
              children: [
                for (var i = 0; i < widget.games.length; i++)
                  Container(
                    width: i == _page ? 16 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: i == _page ? 0.95 : 0.45),
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeriesTile extends StatelessWidget {
  const _SeriesTile({required this.series});
  final Map<String, dynamic> series;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/games/series/${series['id']}'),
      child: SizedBox(
        width: 230,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ArtworkImage(url: series['image'] as String?, icon: Symbols.sports_esports_rounded),
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
                    Text('${series['count']} her', style: const TextStyle(color: Colors.white70)),
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

/// Obal hry na výšku + název a rok (řady her, série).
class GameCover extends StatelessWidget {
  const GameCover({super.key, required this.game, this.width = 140});
  final Map<String, dynamic> game;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => context.push('/games/${game['slug']}'),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child:
                    ArtworkImage(url: (game['cover'] ?? game['hero']) as String?, icon: Symbols.sports_esports_rounded),
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

/// Stránka hry: velký obrázek, skladatel, rok, soundtrack, další díly série.
class GameScreen extends ConsumerWidget {
  const GameScreen({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final game = ref.watch(gameProvider(slug));
    final theme = Theme.of(context);
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: game.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
            message: 'Hru se nepodařilo načíst.', error: e, onRetry: () => ref.invalidate(gameProvider(slug))),
        data: (g) {
          final others = _list(g['seriesGames']);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _GameHeader(game: g)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (g['albumId'] != null)
                        GlassButton(
                          label: 'Přehrát soundtrack',
                          icon: Symbols.play_arrow_rounded,
                          style: GlassButtonStyle.prominent,
                          onPressed: () => context.push('/releases/${g['albumId']}'),
                        )
                      else
                        Text(
                          'Soundtrack téhle hry zatím na streamovacích službách není (nebo jen jako covery, ty nepouštíme).',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      if (g['series'] != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        ActionChip(
                          avatar: const Icon(Symbols.sports_esports_rounded, size: 18),
                          label: Text('Série: ${g['seriesTitle']}'),
                          onPressed: () => context.push('/games/series/${g['series']}'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (others.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Další hry ze série')),
                SliverToBoxAdapter(child: _Rail(height: 250, children: [for (final o in others) GameCover(game: o)])),
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
          ArtworkImage(url: (game['hero'] ?? game['image']) as String?, icon: Symbols.sports_esports_rounded),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x66000000), Color(0x00000000), Color(0xEE000000)],
                stops: [0, 0.4, 1],
              ),
            ),
          ),
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
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
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

/// Stránka série -- jako interpret: hudba ze všech dílů pohromadě.
class GameSeriesScreen extends ConsumerWidget {
  const GameSeriesScreen({super.key, required this.seriesId});
  final String seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = ref.watch(gameSeriesProvider(seriesId));
    return Scaffold(
      bottomNavigationBar: const ShellBarSpace(),
      body: series.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
            message: 'Sérii se nepodařilo načíst.',
            error: e,
            onRetry: () => ref.invalidate(gameSeriesProvider(seriesId))),
        data: (s) {
          final games = _list(s['games']);
          final latest = games.isEmpty ? null : games.last;
          final mixes = _list(s['mixes']).map(HomePlaylistCard.fromJson).toList();
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _GameHeader(
                  game: {'title': s['title'], 'hero': latest?['hero']},
                  subtitle: '${games.length} her · hudba ze všech dílů',
                ),
              ),
              if (mixes.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
                    child: GlassButton(
                      label: 'Přehrát celou sérii (${mixes.first.itemCount} skladeb)',
                      icon: Symbols.play_arrow_rounded,
                      style: GlassButtonStyle.prominent,
                      onPressed: () => context.push('/playlists/${mixes.first.id}'),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SectionHeader('Hry')),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 170,
                    childAspectRatio: 0.52,
                    crossAxisSpacing: AppSpacing.sm,
                    mainAxisSpacing: AppSpacing.sm,
                  ),
                  itemCount: games.length,
                  itemBuilder: (context, i) => GameCover(game: games[i], width: double.infinity),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + navBottomInset(context))),
            ],
          );
        },
      ),
    );
  }
}
