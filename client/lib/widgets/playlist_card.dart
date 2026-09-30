import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/home_repository.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import 'mix_artwork.dart';

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
    this.mix,
  });

  final String title;
  final List<String> coverUrls;
  final bool gradient;
  final IconData icon;
  final bool showTitle;

  /// Denní mix bez karty ("Pokračovat v poslechu") -- `coverUrls` = fotky
  /// interpretů.
  final int? dailyMixNumber;

  /// Generativní obal vlastního mixu (viz `mixArtOf`).
  final MixArtSpec? mix;

  @override
  Widget build(BuildContext context) {
    final spec = mix ??
        (dailyMixNumber == null
            ? null
            : MixArtSpec(
                style: MixArtStyle.daily,
                seed: 'personal:daily-mix:$dailyMixNumber',
                headline: '$dailyMixNumber',
                photos: coverUrls,
              ));
    if (spec != null) return MixArtwork(spec: spec, compact: !showTitle);
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
        const RepaintBoundary(child: CustomPaint(painter: GrainPainter())),
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

/// Karta playlistu do vodorovné řady na Domů.
class PlaylistCardView extends StatelessWidget {
  const PlaylistCardView({super.key, required this.card, required this.onTap, this.width = 150, this.onLongPress});

  final HomePlaylistCard card;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
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
        onLongPress: onLongPress,
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
                        mix: mixArtOf(card),
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
              Text(cardTitle(card), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
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

/// Název pod kartou. Obal vlastního mixu už nese druh ("TOP SKLADBY",
/// "TVŮJ MIX"), pod ním stačí to podstatné -- dřív se uřízl právě letopočet
/// ("Tvoje top skladby 20…", design audit #2).
String cardTitle(HomePlaylistCard card) {
  final s = card.source ?? '';
  if (s.startsWith('personal:year:')) return 'Top skladby ${s.split(':').last}';
  if (s.startsWith('personal:category-mix:')) {
    final i = card.title.indexOf('· ');
    return i < 0 ? card.title : card.title.substring(i + 2);
  }
  return card.title;
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
  const QuickPickTile({super.key, required this.card, required this.onTap, this.onLongPress});

  final HomePlaylistCard card;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = AppShapes.of(Expressive.cornerMedium);
    return GlassPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
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
                  mix: mixArtOf(card),
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
