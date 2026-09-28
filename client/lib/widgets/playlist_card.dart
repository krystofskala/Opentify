import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/home_repository.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;

/// Obal playlistu: mozaika 2×2 z prvních čtyř obalů (1 obal = přes celou
/// plochu), nebo -- u žánrů/nálad, případně bez obalů -- tónovaný zrnitý
/// gradient s názvem. Obsahová vrstva (M3 Expressive), žádné sklo.
class PlaylistArtwork extends StatelessWidget {
  const PlaylistArtwork({
    super.key,
    required this.title,
    this.coverUrls = const [],
    this.gradient = false,
    this.icon = Symbols.queue_music_rounded,
    this.showTitle = true,
    this.dailyMixNumber,
  });

  final String title;
  final List<String> coverUrls;
  final bool gradient;
  final IconData icon;
  final bool showTitle;

  /// Denní mix: vlastní obal místo mozaiky (`coverUrls` = fotky interpretů).
  final int? dailyMixNumber;

  @override
  Widget build(BuildContext context) {
    if (dailyMixNumber != null) {
      return _DailyMixArtwork(number: dailyMixNumber!, artistPhotos: coverUrls, compact: !showTitle);
    }
    if (gradient || coverUrls.isEmpty) return _GradientArtwork(title: title, icon: icon, showTitle: showTitle);
    if (coverUrls.length < 4) return ArtworkImage(url: coverUrls.first, icon: icon);
    return Column(
      children: [
        for (var row = 0; row < 2; row++)
          Expanded(
            child: Row(
              children: [
                for (var col = 0; col < 2; col++)
                  Expanded(child: ArtworkImage(url: coverUrls[row * 2 + col], icon: icon, iconSize: 18)),
              ],
            ),
          ),
      ],
    );
  }
}

class _GradientArtwork extends StatelessWidget {
  const _GradientArtwork({required this.title, required this.icon, required this.showTitle});

  final String title;
  final IconData icon;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Odstín z názvu -- každý žánr má svou stálou barvu, ne všechny stejnou.
    final hue = (title.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xffff) % 360).toDouble();
    final a = HSLColor.fromAHSL(1, hue, 0.62, 0.46).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.7, 0.28).toColor();
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
          ),
        ),
        const RepaintBoundary(child: CustomPaint(painter: _GrainPainter())),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Colors.white.withValues(alpha: 0.85), size: 22),
              const Spacer(),
              if (showTitle)
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                    shadows: const [Shadow(blurRadius: 8, color: Colors.black38)],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Obal "Denního mixu": tónovaný zrnitý gradient (každý mix vlastní stálý
/// odstín), velké číslo a fotky hlavních interpretů v kruzích -- obsahová
/// vrstva podle glass_tokens.dart (tónová barva + expresivní tvary, žádné
/// sklo).
class _DailyMixArtwork extends StatelessWidget {
  const _DailyMixArtwork({required this.number, required this.artistPhotos, required this.compact});

  final int number;
  final List<String> artistPhotos;
  final bool compact;

  static const _hues = [268.0, 12.0, 196.0, 142.0, 330.0, 38.0];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hue = _hues[(number - 1) % _hues.length];
    final a = HSLColor.fromAHSL(1, hue, 0.66, 0.52).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 35) % 360, 0.72, 0.26).toColor();
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final avatar = side * 0.27;
        final photos = artistPhotos.take(compact ? 0 : 3).toList();
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
              ),
            ),
            const RepaintBoundary(child: CustomPaint(painter: _GrainPainter())),
            if (!compact)
              Positioned(
                left: side * 0.08,
                top: side * 0.07,
                child: Text(
                  'DENNÍ MIX',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            Positioned(
              left: side * 0.07,
              bottom: side * (compact ? 0.04 : 0.02),
              child: Text(
                '$number',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: side * (compact ? 0.62 : 0.42),
                  fontWeight: FontWeight.w900,
                  height: 1,
                  shadows: const [Shadow(blurRadius: 10, color: Colors.black38)],
                ),
              ),
            ),
            for (var i = 0; i < photos.length; i++)
              Positioned(
                right: side * 0.06 + i * avatar * 0.6,
                bottom: side * 0.08,
                width: avatar,
                height: avatar,
                child: DecoratedBox(
                  decoration: const ShapeDecoration(
                    shape: CircleBorder(side: BorderSide(color: Colors.white, width: 2)),
                    shadows: [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
                  ),
                  child: ClipOval(child: ArtworkImage(url: photos[i], icon: Symbols.person_rounded, iconSize: 16)),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Statické jemné zrno (stejná estetika jako pozadí appky, jen levné).
class _GrainPainter extends CustomPainter {
  const _GrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(3);
    final count = (size.width * size.height / 14).clamp(200, 4000).toInt();
    final light = <Offset>[];
    final dark = <Offset>[];
    for (var i = 0; i < count; i++) {
      final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      (rnd.nextBool() ? light : dark).add(p);
    }
    final paint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawPoints(ui.PointMode.points, light, paint..color = Colors.white.withValues(alpha: 0.10));
    canvas.drawPoints(ui.PointMode.points, dark, paint..color = Colors.black.withValues(alpha: 0.12));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Karta playlistu do vodorovné řady na Domů.
class PlaylistCardView extends StatelessWidget {
  const PlaylistCardView({super.key, required this.card, required this.onTap, this.width = 150});

  final HomePlaylistCard card;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = AppShapes.of(Expressive.cornerLarge);
    final subtitle = card.description ?? '${card.itemCount} skladeb';
    return SizedBox(
      width: width,
      child: GlassPressable(
        onPressed: onTap,
        shape: AppShapes.of(Expressive.cornerLarge),
        minSize: Size.zero,
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
                      PlaylistArtwork(
                        title: card.title,
                        coverUrls: card.coverUrls,
                        gradient: card.prefersGradient,
                        icon: _iconFor(card.kind),
                        dailyMixNumber: card.dailyMixNumber,
                      ),
                      if (card.badge != null)
                        Positioned(left: AppSpacing.xs, top: AppSpacing.xs, child: RankBadge(label: card.badge!)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (!card.prefersGradient)
              Text(card.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
            Text(
              subtitle,
              maxLines: card.prefersGradient ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _iconFor(String kind) => switch (kind) {
      'CHART' => Symbols.trending_up_rounded,
      'GENRE' => Symbols.graphic_eq_rounded,
      'EDITORIAL' => Symbols.auto_awesome_rounded,
      'GENERATED_RECOMMENDATION' => Symbols.favorite_rounded,
      'PERSONAL_MIX' => Symbols.library_music_rounded,
      _ => Symbols.queue_music_rounded,
    };

/// Štítek žebříčku ("TOP 100") -- tónová kapsle, ne sklo.
class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(color: scheme.primaryContainer, shape: AppShapes.of(AppRadii.pill)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: TextStyle(
              color: scheme.onPrimaryContainer, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4),
        ),
      ),
    );
  }
}

/// Kompaktní dlaždice "Rychlého výběru" (2 sloupce, jako Spotify) --
/// tónový kontejner s mozaikou vlevo a názvem.
class QuickPickTile extends StatelessWidget {
  const QuickPickTile({super.key, required this.card, required this.onTap});

  final HomePlaylistCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = AppShapes.of(Expressive.cornerMedium);
    return GlassPressable(
      onPressed: onTap,
      shape: shape,
      minSize: Size.zero,
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.72)),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: PlaylistArtwork(
                  title: card.title,
                  coverUrls: card.coverUrls,
                  gradient: card.prefersGradient,
                  icon: _iconFor(card.kind),
                  showTitle: false,
                  dailyMixNumber: card.dailyMixNumber,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  card.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}
