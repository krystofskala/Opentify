import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/browse_repository.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/mix_artwork.dart' show GrainPainter;
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/state_views.dart';

/// "Procházet" -- barevné dlaždice nálad a žánrů (jako Spotify), každá vede
/// na vlastní stránku s playlisty, skladbami a alby. Zobrazuje se v Hledat,
/// když není zadaný dotaz.
class BrowseGrid extends ConsumerWidget {
  const BrowseGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(browseCategoriesProvider);
    return categories.when(
      data: (items) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Nálady a chvíle'),
          _Tiles(items: items.where((c) => c.group == 'mood').toList()),
          const SectionHeader('Žánry'),
          _Tiles(items: items.where((c) => c.group == 'genre').toList()),
          if (items.any((c) => c.group == 'soundtrack')) ...[
            const SectionHeader('Soundtracky'),
            _Tiles(items: items.where((c) => c.group == 'soundtrack').toList()),
          ],
        ],
      ),
      loading: () => const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: LoadingState()),
      error: (e, _) => const SizedBox.shrink(),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.items});
  final List<BrowseCategory> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = AppSpacing.xs;
          final w = constraints.maxWidth;
          final columns = w >= 1100 ? 6 : (w >= 720 ? 4 : 2);
          final width = (w - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final c in items) SizedBox(width: width, height: width / 1.75, child: BrowseTile(category: c)),
            ],
          );
        },
      ),
    );
  }
}

IconData browseIcon(String? name) => switch (name) {
      'bedtime' => Symbols.bedtime_rounded,
      'psychology' => Symbols.psychology_rounded,
      'spa' => Symbols.spa_rounded,
      'fitness' => Symbols.fitness_center_rounded,
      'celebration' => Symbols.celebration_rounded,
      'sunny' => Symbols.sunny_rounded,
      'favorite' => Symbols.favorite_rounded,
      'rainy' => Symbols.rainy_rounded,
      'coffee' => Symbols.coffee_rounded,
      'car' => Symbols.directions_car_rounded,
      'gamepad' => Symbols.sports_esports_rounded,
      'movie' => Symbols.movie_rounded,
      _ => Symbols.music_note_rounded,
    };

/// Žánry mají ze serveru všechny stejnou ikonu (notu) -- vlastní symbol
/// podle id, ať se od sebe dají rozeznat.
IconData _genreIcon(String id) => switch (id) {
      'pop' => Symbols.mic_external_on_rounded,
      'hiphop' => Symbols.mic_rounded,
      'rock' => Symbols.electric_bolt_rounded,
      'indie' => Symbols.album_rounded,
      'electronic' => Symbols.graphic_eq_rounded,
      'dance' => Symbols.nightlife_rounded,
      'rnb' => Symbols.headphones_rounded,
      'jazz' => Symbols.local_bar_rounded,
      'classical' => Symbols.piano_rounded,
      'folk' => Symbols.forest_rounded,
      'metal' => Symbols.skull_rounded,
      'soul' => Symbols.radio_rounded,
      'country' => Symbols.agriculture_rounded,
      'bluegrass' => Symbols.grass_rounded,
      'blues' => Symbols.nightlight_rounded,
      'reggae' => Symbols.beach_access_rounded,
      'latin' => Symbols.festival_rounded,
      'brazil' => Symbols.surfing_rounded,
      'african' => Symbols.public_rounded,
      'asian' => Symbols.stars_rounded,
      'indian' => Symbols.theaters_rounded,
      'kids' => Symbols.toys_rounded,
      _ => Symbols.music_note_rounded,
    };

IconData categoryIcon(BrowseCategory c) => c.group == 'genre' ? _genreIcon(c.id) : browseIcon(c.icon);

/// Dlaždice kategorie (varianta "Tvar"): tmavý tón barvy kategorie, jeden
/// velký M3 Expressive tvar se zrnitým gradientem, vyjíždějící zprava dole,
/// a v něm symbol kategorie. Nálady = cookie, žánry = květ, soundtracky =
/// čtyřlístek; natočení podle id, takže každá dlaždice je stálá a jiná.
class BrowseTile extends StatelessWidget {
  const BrowseTile({super.key, required this.category});
  final BrowseCategory category;

  @override
  Widget build(BuildContext context) {
    final shape = AppShapes.of(Expressive.cornerMedium);
    final hsl = HSLColor.fromColor(category.color);
    Color tone(double s, double l, [double dh = 0]) => hsl
        .withHue((hsl.hue + dh) % 360)
        .withSaturation((hsl.saturation * s).clamp(0.0, 1.0))
        .withLightness(l.clamp(0.0, 1.0))
        .toColor();
    return GlassPressable(
      shape: shape,
      minSize: Size.zero,
      onPressed: () => context.push('/browse/${category.id}'),
      // Přes celou buňku -- jinak se dlaždice scvrkla na velikost textu.
      child: SizedBox.expand(
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tone(0.7, hsl.lightness * 0.5 + 0.02), tone(0.7, hsl.lightness * 0.32, 15)],
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final h = constraints.maxHeight;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    const RepaintBoundary(child: CustomPaint(painter: GrainPainter())),
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _TileShapePainter(
                          group: category.group,
                          seed: category.id,
                          from: tone(1.15, 0.66, 10),
                          to: tone(1.0, 0.38, 40),
                        ),
                      ),
                    ),
                    Positioned(
                      right: constraints.maxWidth * 0.13,
                      bottom: h * 0.13,
                      child: Icon(
                        categoryIcon(category),
                        size: h * 0.34,
                        fill: 1,
                        color: Colors.white,
                        shadows: const [Shadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Builder(builder: (context) {
                          // Úzká dlaždice (4 sloupce na desktopu): nejdelší slovo se
                          // musí vejít celé -- dřív "Latinskoamer/ická" a "K-/pop".
                          final title = category.title.replaceAll('-', '‑');
                          var style = Theme.of(context).textTheme.titleMedium!.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            height: 1.1,
                            shadows: const [Shadow(blurRadius: 6, color: Colors.black26)],
                          );
                          final available = constraints.maxWidth - 2 * AppSpacing.sm;
                          final scaler = MediaQuery.textScalerOf(context);
                          var widest = 0.0;
                          for (final word in title.split(' ')) {
                            final tp = TextPainter(
                              text: TextSpan(text: word, style: style),
                              textDirection: TextDirection.ltr,
                              textScaler: scaler,
                              maxLines: 1,
                            )..layout();
                            widest = widest > tp.width ? widest : tp.width;
                            tp.dispose();
                          }
                          if (widest > available && available > 0) {
                            style = style.copyWith(fontSize: (style.fontSize ?? 16) * available / widest);
                          }
                          return Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TileShapePainter extends CustomPainter {
  const _TileShapePainter({required this.group, required this.seed, required this.from, required this.to});

  final String group;
  final String seed;
  final Color from;
  final Color to;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = switch (group) {
      'genre' => const ExpressiveShape.cookie(lobes: 5, depth: 0.26),
      'soundtrack' => const ExpressiveShape.cookie(lobes: 4, depth: 0.22),
      _ => const ExpressiveShape.cookie(lobes: 9, depth: 0.08),
    };
    final h = size.height;
    final r = h * 0.78;
    final rect = Rect.fromCircle(center: Offset(size.width * 0.84, h * 0.78), radius: r);
    final spin = (seed.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0xffff) % 628) / 100;
    paintGrainShape(canvas, expressivePath(rect, shape, null, 0, spin), rect, 0, from: from, to: to);
  }

  @override
  bool shouldRepaint(covariant _TileShapePainter old) =>
      old.group != group || old.seed != seed || old.from != from || old.to != to;
}
