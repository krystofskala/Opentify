import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
    final scheme = theme.colorScheme;
    final shape = AppShapes.of(Expressive.cornerLarge);
    // Sklo jako zbytek appky (lehce tónované barvou roku); barva a zrno jsou
    // jen uvnitř hravých tvarů -- ne plný barevný pruh.
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: GlassPressable(
        shape: shape,
        minSize: Size.zero,
        onPressed: () => context.push('/wrapped/$period'),
        child: GlassContainer(
          borderRadius: BorderRadius.circular(Expressive.cornerLarge),
          tint: HSLColor.fromAHSL(1, hue, 0.6, 0.45).toColor(),
          tintOpacity: 0.14,
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
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Minuty, interpreti, žánry a obrázky ke sdílení',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              SizedBox.square(
                dimension: 46,
                child: CustomPaint(
                  painter: _GrainShapePainter(hue: hue + 30, shape: const ExpressiveShape.cookie(lobes: 7, depth: 0.1)),
                  child: const Icon(Symbols.play_arrow_rounded, color: Colors.white, fill: 1, size: 26),
                ),
              ),
            ],
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

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final angle = t * 2 * math.pi;
    // Malý čtyřlístek vlevo nahoře (otáčí se opačně).
    final cloverRect = Rect.fromLTWH(0, 0, w * 0.42, w * 0.42);
    paintGrainShape(canvas, expressivePath(cloverRect, _clover, null, 0, -angle * 1.5), cloverRect, hue - 40);
    // Velký cookie, který se pomalu přelévá do květu a zpět.
    final morph = 0.5 - 0.5 * math.cos(angle);
    final mainRect = Rect.fromLTWH(w * 0.12, w * 0.12, w * 0.8, w * 0.8);
    paintGrainShape(canvas, expressivePath(mainRect, _cookie, _flower, morph, angle), mainRect, hue + 30);
    // Kolečko vpravo dole.
    final dotRect = Rect.fromCircle(center: Offset(w * 0.86, w * 0.84), radius: w * 0.12);
    paintGrainShape(canvas, Path()..addOval(dotRect), dotRect, hue + 160);
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

/// Tvar vyplněný zrnitým gradientem (estetika pozadí appky a obalů mixů):
/// úhlopříčný přechod dvou tónů, zrno a jemný lesk nahoře -- vše oříznuté
/// na `path`.
void paintGrainShape(Canvas canvas, Path path, Rect rect, double hue) {
  Color c(double shift, double s, double l) => HSLColor.fromAHSL(1, (hue + shift) % 360, s, l).toColor();
  canvas.save();
  canvas.clipPath(path);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [c(0, 0.75, 0.66), c(40, 0.7, 0.36)],
      ).createShader(rect),
  );
  // Zrno jako pozadí appky: husté (bod na každý ~0,7 px²), drobné body a
  // slabé krytí s trojúhelníkovým rozdělením síly -- řídké silné tečky
  // působily jako fleky, ne zrno. Stálé (seed z rozměru), ať při otáčení
  // neblikne.
  final buckets = _grainFor(rect.size);
  final grain = Paint()
    ..strokeWidth = 0.75
    ..strokeCap = StrokeCap.square;
  canvas.save();
  canvas.translate(rect.left, rect.top);
  for (var i = 0; i < 6; i++) {
    final alpha = 0.05 + 0.045 * (i % 3);
    grain.color = (i < 3 ? Colors.white : Colors.black).withValues(alpha: alpha);
    canvas.drawRawPoints(ui.PointMode.points, buckets[i], grain);
  }
  canvas.restore();
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

/// Body zrna pro danou velikost -- spočítané jednou (tvary se animují, zrno
/// se nemá generovat každý snímek). 6 skupin: 3 síly světlých, 3 tmavých.
final Map<Size, List<Float32List>> _grainCache = {};

List<Float32List> _grainFor(Size size) => _grainCache.putIfAbsent(size, () {
      final rnd = math.Random(size.width.round());
      final count = (size.width * size.height * 1.4).clamp(200, 9000).toInt();
      final buckets = List.generate(6, (_) => <double>[]);
      for (var i = 0; i < count; i++) {
        final g = rnd.nextDouble() + rnd.nextDouble() - 1; // -1..1
        if (g.abs() < 0.15) continue;
        final level = math.min(2, (g.abs() * 3).floor());
        buckets[level + (g > 0 ? 0 : 3)]
          ..add(rnd.nextDouble() * size.width)
          ..add(rnd.nextDouble() * size.height);
      }
      return [for (final b in buckets) Float32List.fromList(b)];
    });

/// Jeden (statický) tvar se zrnitým gradientem -- tlačítko přehrání.
class _GrainShapePainter extends CustomPainter {
  const _GrainShapePainter({required this.hue, required this.shape});
  final double hue;
  final ExpressiveShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    paintGrainShape(canvas, expressivePath(rect, shape), rect, hue);
  }

  @override
  bool shouldRepaint(covariant _GrainShapePainter old) => old.hue != hue || old.shape != shape;
}
