import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';

/// Připnutá dlaždice nahoře v Knihovně › Playlisty (Oblíbené, Poslechnout
/// později, Sdílené, Shazam) -- čtyři v mřížce 2×2, ať je pod nimi vidět
/// víc vlastních playlistů (dřív čtyři plné řádky přes celou šířku).
class PinnedTile extends StatelessWidget {
  const PinnedTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colors,
    required this.iconBackground,
    required this.iconColor,
    required this.textColor,
    required this.onTap,
    this.iconFill = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> colors;
  final Color iconBackground;
  final Color iconColor;
  final Color textColor;
  final VoidCallback onTap;
  final bool iconFill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = AppShapes.of(Expressive.cornerExtraLarge);
    return GlassPressable(
      onPressed: onTap,
      shape: shape,
      minSize: Size.zero,
      semanticLabel: title,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SizedBox(
            height: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: ShapeDecoration(shape: AppShapes.of(Expressive.cornerMedium), color: iconBackground),
                      child: SizedBox.square(
                        dimension: 44,
                        child: Icon(icon, fill: iconFill ? 1 : 0, color: iconColor, size: 24),
                      ),
                    ),
                    const Spacer(),
                    Icon(Symbols.chevron_right_rounded, color: textColor.withValues(alpha: 0.7)),
                  ],
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(color: textColor, fontWeight: FontWeight.w700),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: textColor.withValues(alpha: 0.8)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mřížka 2×2 připnutých dlaždic.
class PinnedGrid extends StatelessWidget {
  const PinnedGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i += 2) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(child: children[i]),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox.shrink()),
            ],
          ),
        ],
      ],
    );
  }
}
