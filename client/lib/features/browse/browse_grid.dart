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
      _ => Symbols.music_note_rounded,
    };

/// Barevná dlaždice kategorie: gradient z barvy kategorie, název vlevo
/// nahoře, velká natočená ikona vpravo dole (Spotify motiv).
class BrowseTile extends StatelessWidget {
  const BrowseTile({super.key, required this.category});
  final BrowseCategory category;

  @override
  Widget build(BuildContext context) {
    final shape = AppShapes.of(Expressive.cornerMedium);
    final hsl = HSLColor.fromColor(category.color);
    final darker = hsl.withLightness((hsl.lightness * 0.6).clamp(0.0, 1.0)).toColor();
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
                colors: [category.color, darker],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  right: -8,
                  bottom: -10,
                  child: Transform.rotate(
                    angle: 0.35,
                    child: Icon(browseIcon(category.icon), size: 64, color: Colors.white.withValues(alpha: 0.35)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      category.title,
                      maxLines: 2,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                        shadows: const [Shadow(blurRadius: 6, color: Colors.black26)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
