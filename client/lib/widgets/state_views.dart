import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api_client.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/expressive_shapes.dart';
import 'glass/glass.dart';

/// Jednotné stavové widgety (nadpis sekce, prázdno, chyba, načítání) pro
/// celou appku -- dřív si každá obrazovka psala vlastní `_SectionHeader`/
/// `_EmptyState`/holý `CircularProgressIndicator`/`Text('Nepodařilo se...')`
/// s mírně odlišnými paddingy, styly i texty.

/// Nadpis sekce -- volitelný štítek vedle názvu a "Zobrazit vše" vpravo.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.badge, this.onSeeAll, this.trailing, this.padding});

  final String title;
  final Widget? badge;
  final VoidCallback? onSeeAll;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.xs, AppSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 22/w800: pod nadpisem stránky (28-34/w900), ať hierarchie
                    // nahoře není plochá (design audit).
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: AppFontSize.heading, fontWeight: FontWeight.w800),
                  ),
                ),
                if (badge != null) ...[const SizedBox(width: AppSpacing.xs), badge!],
              ],
            ),
          ),
          if (trailing != null) trailing!,
          // `primary` z tónové palety (tmavý režim světlý tón, světlý režim
          // tmavý) drží kontrast ≥ 4.5:1 a odliší akci od nadpisu.
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
                textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              child: const Text('Zobrazit vše'),
            ),
        ],
      ),
    );
  }
}

/// Barevný štítek vedle nadpisu sekce ("Pro tebe", "Trendy"...).
class SectionBadge extends StatelessWidget {
  const SectionBadge({super.key, required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: ShapeDecoration(
          // Plná tónová výplň (M3), ne průsvitná -- čitelná na jakémkoliv
          // místě barevného pozadí.
          color: Color.alphaBlend(color.withValues(alpha: 0.22), Theme.of(context).colorScheme.surfaceContainerHighest),
          shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.35))),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: AppSpacing.xxs),
              Text(label, style: TextStyle(fontSize: AppFontSize.tiny, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
        ),
      );
}

/// Prázdný stav -- `compact` pro inline použití uvnitř sekce (Home rail),
/// jinak vycentrovaný s ikonou (celá obrazovka/tab).
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon = Symbols.music_off_rounded, this.compact = false, this.action});

  final String message;
  final IconData icon;
  final bool compact;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.sm),
            Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
            if (action != null) ...[const SizedBox(height: AppSpacing.md), action!],
          ],
        ),
      ),
    );
  }
}

/// Chybový stav -- volitelné "Zkusit znovu".
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.error, this.onRetry, this.compact = false});

  final String message;
  final Object? error;
  final VoidCallback? onRetry;
  final bool compact;

  /// Lidská věta místo syrové výjimky ("ApiException(502): {...}").
  String get _detail {
    final e = error;
    if (e == null) return '';
    if (e is TimeoutException) return 'Server neodpověděl včas.';
    if (e is ApiException) {
      final d = e.detail;
      if (d != null) return d;
      if (e.statusCode >= 500) return 'Server má potíže (${e.statusCode}).';
      if (e.statusCode == 404) return 'Tohle už neexistuje.';
      return 'Chyba ${e.statusCode}.';
    }
    final raw = e.toString();
    if (raw.contains('ClientException') || raw.contains('XMLHttpRequest') || raw.contains('SocketException')) {
      return 'Nejde se spojit se serverem – je zapnutý Tailscale?';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retry = onRetry == null
        ? null
        : GlassButton(
            label: 'Zkusit znovu',
            icon: Symbols.refresh_rounded,
            style: GlassButtonStyle.tonal,
            compact: true,
            onPressed: onRetry,
          );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        child: Row(
          children: [
            Icon(Symbols.error_rounded, size: 20, color: theme.colorScheme.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error))),
            if (retry != null) retry,
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.cloud_off_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.sm),
            Text(message, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            if (_detail.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xxs),
              Text(
                _detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (retry != null) ...[const SizedBox(height: AppSpacing.md), retry],
          ],
        ),
      ),
    );
  }
}

/// Pulzující šedý obdélník -- stavební kámen všech skeletonů.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height, this.radius = AppRadii.sm});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    return DecoratedBox(
      decoration: ShapeDecoration(color: color, shape: AppShapes.of(radius)),
      child: SizedBox(width: width, height: height),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fade(begin: 0.5, end: 1, duration: 800.ms, curve: Curves.easeInOut);
  }
}

/// Skeleton řádků skladeb (stejné rozměry jako `TrackTile` row layout).
class SkeletonTrackList extends StatelessWidget {
  const SkeletonTrackList({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
            child: Row(
              children: [
                SkeletonBox(width: 44, height: 44),
                SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(height: 12, width: 180, radius: AppRadii.xs),
                      SizedBox(height: 6),
                      SkeletonBox(height: 10, width: 110, radius: AppRadii.xs),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Skeleton vodorovné řady karet (Home rails, diskografie).
class SkeletonCardRail extends StatelessWidget {
  const SkeletonCardRail({super.key, this.height = 198, this.cardWidth = 140, this.circle = false});

  final double height;
  final double cardWidth;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        itemCount: 6,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: cardWidth, height: cardWidth, radius: circle ? AppRadii.pill : AppRadii.sm),
                const SizedBox(height: AppSpacing.xs),
                SkeletonBox(width: cardWidth * 0.8, height: 12, radius: AppRadii.xs),
                const SizedBox(height: 6),
                SkeletonBox(width: cardWidth * 0.5, height: 10, radius: AppRadii.xs),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Celoplošné načítání (tab, obrazovka) -- skeleton seznamu místo holého
/// spinneru, ať layout neposkakuje, když data dorazí.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: SkeletonTrackList(count: count),
      );
}

/// Kompaktní spinner (stránkování na konci seznamu apod.).
class InlineSpinner extends StatelessWidget {
  const InlineSpinner({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: ExpressiveLoadingIndicator(size: 32)),
      );
}
