import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import '../mix_artwork.dart' show GrainPainter;

/// Tvary M3 Expressive ("shape library" -- squircle, cookie/scallop,
/// květ...) definované polárně, takže mezi nimi jde plynule morfovat
/// (m3.material.io/styles/shape). Hravé tvary jen pro výrazné prvky
/// (play tlačítko, načítání, avatar) -- běžné plochy zůstávají squircle.
@immutable
class ExpressiveShape {
  const ExpressiveShape.cookie({this.lobes = 9, this.depth = 0.08})
      : squareness = 0,
        rotation = 0;

  const ExpressiveShape.squircle({this.squareness = 1})
      : lobes = 0,
        depth = 0,
        rotation = 0;

  const ExpressiveShape.circle()
      : lobes = 0,
        depth = 0,
        squareness = 0,
        rotation = 0;

  final int lobes;
  final double depth;

  /// 0 = kruh, 1 = squircle (superelipsa p=4).
  final double squareness;
  final double rotation;

  /// Poloměr (0..1 z vnějšího) pro úhel `theta`.
  double radiusAt(double theta) {
    final a = theta + rotation;
    var r = 1.0;
    if (lobes > 0 && depth > 0) r *= 1 - depth * (0.5 - 0.5 * math.cos(lobes * a));
    if (squareness > 0) {
      // Superelipsa |x|^4 + |y|^4 = 1 -- na osách dosahuje okraje, na
      // úhlopříčce 2^(1/4); ×0.92 aby opticky odpovídala velikosti kruhu.
      const p = 4.0;
      final sq = 1 / math.pow(math.pow(math.cos(a).abs(), p) + math.pow(math.sin(a).abs(), p), 1 / p);
      r = r * (1 - squareness) + sq * 0.92 * squareness;
    }
    return r;
  }
}

/// Cesta tvaru uprostřed `rect`, případně morf mezi `a` a `b` (`t` 0..1).
Path expressivePath(Rect rect, ExpressiveShape a, [ExpressiveShape? b, double t = 0, double spin = 0]) {
  const steps = 180;
  final c = rect.center;
  final radius = rect.shortestSide / 2;
  final path = Path();
  for (var i = 0; i <= steps; i++) {
    final theta = 2 * math.pi * i / steps;
    final ra = a.radiusAt(theta);
    final r = b == null ? ra : ra + (b.radiusAt(theta) - ra) * t;
    final pt = Offset(c.dx + radius * r * math.cos(theta + spin), c.dy + radius * r * math.sin(theta + spin));
    i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
  }
  return path..close();
}

/// Plocha, která pružinou (`Expressive.spatialDefault`) morfuje mezi tvary
/// při změně `shape` (např. play = cookie, pause = squircle).
class ExpressiveMorph extends StatefulWidget {
  const ExpressiveMorph({super.key, required this.shape, required this.color, required this.child, this.size = 96});

  final ExpressiveShape shape;
  final Color color;
  final Widget child;
  final double size;

  @override
  State<ExpressiveMorph> createState() => _ExpressiveMorphState();
}

class _ExpressiveMorphState extends State<ExpressiveMorph> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: Motion.enter.duration)..value = 1;
  late ExpressiveShape _from = widget.shape;
  late ExpressiveShape _to = widget.shape;

  @override
  void didUpdateWidget(covariant ExpressiveMorph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shape != widget.shape) {
      _from = _to;
      _to = widget.shape;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => CustomPaint(
        painter: _ShapePainter(
          from: _from,
          to: _to,
          t: Motion.enter.transform(_controller.value),
          color: widget.color,
        ),
        child: child,
      ),
      child: SizedBox.square(dimension: widget.size, child: Center(child: widget.child)),
    );
  }
}

class _ShapePainter extends CustomPainter {
  const _ShapePainter({required this.from, required this.to, required this.t, required this.color, this.spin = 0});

  final ExpressiveShape from;
  final ExpressiveShape to;
  final double t;
  final double spin;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(expressivePath(Offset.zero & size, from, to, t, spin), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ShapePainter old) =>
      old.t != t || old.from != from || old.to != to || old.color != color || old.spin != spin;
}

/// M3 Expressive indikátor načítání: tvar, který se otáčí a plynule
/// přechází mezi tvary knihovny (místo prostého kolečka).
/// Při "Omezit pohyb" jen pomalu pulzuje průhlednost (HIG Accessibility).
class ExpressiveLoadingIndicator extends StatefulWidget {
  const ExpressiveLoadingIndicator({super.key, this.size = 40, this.color});

  final double size;
  final Color? color;

  @override
  State<ExpressiveLoadingIndicator> createState() => _ExpressiveLoadingIndicatorState();
}

class _ExpressiveLoadingIndicatorState extends State<ExpressiveLoadingIndicator> with SingleTickerProviderStateMixin {
  static const _sequence = [
    ExpressiveShape.cookie(lobes: 7, depth: 0.12),
    ExpressiveShape.cookie(lobes: 4, depth: 0.22),
    ExpressiveShape.squircle(),
    ExpressiveShape.cookie(lobes: 9, depth: 0.08),
  ];

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: 'Načítání',
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final v = _controller.value;
            if (reduceMotion) {
              return Opacity(
                opacity: 0.5 + 0.5 * math.sin(v * 2 * math.pi).abs(),
                child: CustomPaint(painter: _ShapePainter(from: _sequence[0], to: _sequence[0], t: 0, color: color)),
              );
            }
            final phase = v * _sequence.length;
            final i = phase.floor() % _sequence.length;
            final local = Motion.enter.transform((phase - phase.floor()).clamp(0.0, 1.0));
            return CustomPaint(
              painter: _ShapePainter(
                from: _sequence[i],
                to: _sequence[(i + 1) % _sequence.length],
                t: local,
                spin: v * 2 * math.pi * 2,
                color: color,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Tvar vyplněný zrnitým gradientem (estetika pozadí appky a obalů mixů):
/// úhlopříčný přechod dvou tónů, zrno a jemný lesk nahoře -- vše oříznuté
/// na `path`.
///
/// Barvy buď z `hue` (hravé tvary Wrapped), nebo přímo `from`/`to`
/// (tvary v barvě stránky -- hlavička detailu).
void paintGrainShape(Canvas canvas, Path path, Rect rect, double hue, {Color? from, Color? to}) {
  Color c(double shift, double s, double l) => HSLColor.fromAHSL(1, (hue + shift) % 360, s, l).toColor();
  canvas.save();
  canvas.clipPath(path);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [from ?? c(0, 0.75, 0.66), to ?? c(40, 0.7, 0.36)],
      ).createShader(rect),
  );
  // Zrno jako pozadí appky -- sdílená předpočítaná dlaždice opakovaná přes
  // plochu. Dřív se kreslilo bod po bodu (~100 000 bodů na tvar): web
  // nemá cache hotových kreseb, takže s animovaným pozadím se to překreslovalo
  // každý snímek a Hledat (24 dlaždic) se sekalo (živě nahlášeno).
  canvas.drawRect(rect, Paint()..shader = GrainPainter.shader());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.center,
        colors: [Colors.white.withValues(alpha: 0.25), Colors.white.withValues(alpha: 0)],
      ).createShader(rect),
  );
  canvas.restore();
}
