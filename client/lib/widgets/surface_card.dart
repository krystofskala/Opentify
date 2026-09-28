import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import 'glass_container.dart';

/// Plochý panel pro OBSAH (karty v profilu, souhrny) -- protějšek skla pro
/// obsahovou vrstvu. HIG Materials: "Don't use Liquid Glass in the content
/// layer" -- obsahové panely jsou neprůhledné/tónované plochy, sklo patří
/// jen plovoucím ovládacím prvkům (viz `theme/glass_tokens.dart`).
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(AppSpacing.md)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: glassShape(const BorderRadius.all(Radius.circular(AppRadii.lg))),
        color: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerHigh,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
