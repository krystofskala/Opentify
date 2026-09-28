import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';

/// "Liquid Glass" efekt -- poloprůhledné rozostřené pozadí se zvýšenou
/// sytostí (viz `GlassTokens.saturation` -- přesně tohle chybělo mezi naším
/// původním plochým blur+gradient efektem a skutečným Apple Liquid
/// Glass/PixelPlay vzhledem, github.com/rdev/liquid-glass-react má
/// `saturation` výchozí na 140 %), jemný okraj, stín a tenký "catches the
/// light" highlight po obvodu. Sdílený základ pro `PlayerBar`, hlavičky
/// Release/Artist a karty v mřížkách, aby měla appka jednotný vizuální jazyk
/// místo řešení blur efektu zvlášť na každém místě.
///
/// Mimo scope zůstává myší tažená `feDisplacementMap` refrakce/elasticita ze
/// stejné referenční knihovny -- ta by vyžadovala vlastní `dart:ui`
/// `FragmentShader`, ne jen `BackdropFilter`.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.lg)),
    this.blurSigma = GlassTokens.blurMedium,
    this.saturation = GlassTokens.saturation,
    this.tint,
    this.padding,
    this.showEdgeHighlight = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double saturation;
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final bool showEdgeHighlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = tint ?? theme.colorScheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        children: [
          BackdropFilter(
            // `outer` (sytost) se aplikuje na výsledek `inner` (blur) --
            // stejné pořadí jako CSS `backdrop-filter: blur() saturate()`.
            filter: ImageFilter.compose(
              outer: saturationColorFilter(saturation),
              inner: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            ),
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
                border: Border.all(color: Colors.white.withValues(alpha: GlassTokens.borderAlpha)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8)),
                ],
              ),
              child: child,
            ),
          ),
          if (showEdgeHighlight)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _GlassEdgeHighlightPainter(borderRadius: borderRadius)),
              ),
            ),
        ],
      ),
    );
  }
}

class _GlassEdgeHighlightPainter extends CustomPainter {
  const _GlassEdgeHighlightPainter({required this.borderRadius});

  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect).deflate(0.75);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: GlassTokens.edgeHighlightAlpha),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _GlassEdgeHighlightPainter oldDelegate) => oldDelegate.borderRadius != borderRadius;
}
