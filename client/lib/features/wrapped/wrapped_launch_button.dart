import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/glass/glass.dart';

/// Wrapped období, ke kterému playlist patří (`personal:year:2019` -> 2019,
/// playlisty dekády -> decade), jinak `null`.
String? wrappedPeriodForSource(String? source) {
  final s = source ?? '';
  if (s.startsWith('personal:year:')) return s.substring('personal:year:'.length);
  if (s.startsWith('personal:decade:')) return 'decade';
  return null;
}

/// Karta "Tvůj Wrapped 2019" nad ročním playlistem -- shluk hravých M3
/// Expressive tvarů (otáčející se "cookie", který přechází mezi tvary),
/// v barvě roku jako obal playlistu.
class WrappedLaunchCard extends StatelessWidget {
  const WrappedLaunchCard({super.key, required this.period});

  final String period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decade = period == 'decade';
    final year = int.tryParse(period) ?? 0;
    final hue = decade ? 36.0 : (year * 47 + 20) % 360.0;
    final shape = AppShapes.of(Expressive.cornerLarge);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: GlassPressable(
        shape: shape,
        minSize: Size.zero,
        onPressed: () => context.push('/wrapped/$period'),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            gradient: LinearGradient(
              colors: [
                HSLColor.fromAHSL(1, hue, 0.6, 0.42).toColor(),
                HSLColor.fromAHSL(1, (hue + 40) % 360, 0.65, 0.22).toColor(),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                _FunShapes(hue: hue),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        decade ? 'Tvoje dekáda' : 'Tvůj Wrapped $period',
                        style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Minuty, interpreti, žánry a obrázky ke sdílení',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                      ),
                    ],
                  ),
                ),
                const Icon(Symbols.play_circle_rounded, color: Colors.white, size: 32, fill: 1),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FunShapes extends StatefulWidget {
  const _FunShapes({required this.hue});
  final double hue;

  @override
  State<_FunShapes> createState() => _FunShapesState();
}

class _FunShapesState extends State<_FunShapes> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 9));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 76,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) => CustomPaint(painter: _FunShapesPainter(widget.hue, _spin.value)),
      ),
    );
  }
}

class _FunShapesPainter extends CustomPainter {
  _FunShapesPainter(this.hue, this.t);
  final double hue;
  final double t;

  static const _cookie = ExpressiveShape.cookie(lobes: 9, depth: 0.1);
  static const _flower = ExpressiveShape.cookie(lobes: 5, depth: 0.28);
  static const _clover = ExpressiveShape.cookie(lobes: 4, depth: 0.22);

  Color _c(double shift, double l) => HSLColor.fromAHSL(1, (hue + shift) % 360, 0.8, l).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final angle = t * 2 * math.pi;
    // Malý čtyřlístek vlevo nahoře (otáčí se opačně).
    canvas.drawPath(
      expressivePath(Rect.fromLTWH(0, 0, w * 0.42, w * 0.42), _clover, null, 0, -angle * 1.5),
      Paint()..color = _c(-40, 0.7),
    );
    // Velký cookie, který se pomalu přelévá do květu a zpět.
    final morph = 0.5 - 0.5 * math.cos(angle);
    canvas.drawPath(
      expressivePath(Rect.fromLTWH(w * 0.12, w * 0.12, w * 0.8, w * 0.8), _cookie, _flower, morph, angle),
      Paint()..color = _c(30, 0.66),
    );
    // Kolečko vpravo dole.
    canvas.drawCircle(Offset(w * 0.86, w * 0.84), w * 0.12, Paint()..color = _c(160, 0.75));
    // Nota uprostřed.
    const icon = Symbols.music_note_rounded;
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: w * 0.36,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
          fontVariations: const [FontVariation('FILL', 1)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(w * 0.52 - painter.width / 2, w * 0.52 - painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _FunShapesPainter old) => old.t != t || old.hue != hue;
}
