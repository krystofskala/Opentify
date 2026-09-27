import 'dart:ui';

import 'package:flutter/material.dart';

/// "Liquid Glass" efekt -- poloprůhledné rozostřené pozadí, jemný okraj a
/// stín. Sdílený základ pro `PlayerBar`, hlavičky Release/Artist a karty
/// v mřížkách, aby měla appka jednotný vizuální jazyk místo řešení blur
/// efektu zvlášť na každém místě.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blurSigma = 20,
    this.tint,
    this.padding,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final Color? tint;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = tint ?? theme.colorScheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [base.withValues(alpha: 0.55), base.withValues(alpha: 0.30)],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
