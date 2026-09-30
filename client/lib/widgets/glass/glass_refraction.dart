import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../theme/glass_tokens.dart' show vibrancyColorFilter;

/// Lom světla na zaobleném okraji skla (Liquid Glass): v pruhu u hrany se
/// SKUTEČNÝ obsah pod sklem (obaly, text, zrno pozadí) zvětšuje směrem ke
/// středu -- obraz se u hrany natahuje, jako by se ohýbal přes zaoblení.
/// Síla podle Snellova zákona na profilu "squircle" (n = 1.5, paprsek jde
/// celou tloušťkou skla, takže nejsilněji přímo u hrany), hodnoty ze
/// schváleného náhledu (22 px okraj, síla 25 px).
///
/// Prohlížeč neumí posunout pozadí po pixelech, takže pruh je rozdělený na
/// soustředné prstence a každý je jeden `BackdropFilter` se zvětšením
/// (`ImageFilter.matrix`) kolem středu prvku. Směrem k hraně čím dál méně
/// rozmazání -- hrana je čirá, střed mléčný (rozmazání středu kreslí
/// `GlassContainer`, ten má vnitřek oříznutý na `innerInset`).
class GlassRefraction extends LeafRenderObjectWidget {
  const GlassRefraction({super.key, required this.borderRadius, required this.blurSigma, this.saturation = 1});

  final BorderRadius borderRadius;

  /// Vibrance jako ve středu skla (sytost obsahu za sklem).
  final double saturation;

  /// Rozmazání středu skla; prstence mají jeho zlomek.
  final double blurSigma;

  /// Šířka pruhu s lomem -- vnitřek skla od ní dál.
  static const double innerInset = _bezel;

  static const double _bezel = 22;
  static const double _strength = 25;
  // Prstence od hrany dovnitř (px) a podíl rozmazání středu v každém.
  static const List<double> _edges = [0, 4, 10, 22];
  static const List<double> _blurShare = [0.15, 0.35, 0.65];
  static final List<double> _shift = _ringShifts();

  /// Posun obrazu uprostřed každého prstence: Δ = (tloušťka + y(x)) ·
  /// tan(θ1 − θ2), θ1 = sklon profilu, sin θ2 = sin θ1 / 1.5, normováno.
  static List<double> _ringShifts() {
    double f(double x) => math.pow(math.max(0.0, 1 - math.pow(1 - x, 4)), 0.25).toDouble();
    double shift(double x) {
      const e = 0.002;
      final slope = (f(math.min(1.0, x + e)) - f(math.max(0.0, x - e))) / (2 * e);
      final t1 = math.atan(slope);
      final t2 = math.asin(math.sin(t1) / 1.5);
      return (0.8 + f(x)) * math.tan(t1 - t2);
    }

    var max = 0.0;
    for (var i = 1; i <= 256; i++) {
      max = math.max(max, shift(i / 256));
    }
    return [
      for (var i = 0; i < _edges.length - 1; i++) shift(((_edges[i] + _edges[i + 1]) / 2) / _bezel) / max * _strength,
    ];
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderGlassRefraction(borderRadius: borderRadius, blurSigma: blurSigma, saturation: saturation);

  @override
  void updateRenderObject(BuildContext context, RenderGlassRefraction renderObject) {
    renderObject
      ..borderRadius = borderRadius
      ..blurSigma = blurSigma
      ..saturation = saturation;
  }
}

class RenderGlassRefraction extends RenderBox {
  RenderGlassRefraction({required BorderRadius borderRadius, required double blurSigma, required double saturation})
      : _borderRadius = borderRadius,
        _blurSigma = blurSigma,
        _saturation = saturation;

  double _saturation;
  set saturation(double value) {
    if (value == _saturation) return;
    _saturation = value;
    markNeedsPaint();
  }

  BorderRadius _borderRadius;
  set borderRadius(BorderRadius value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  double _blurSigma;
  set blurSigma(double value) {
    if (value == _blurSigma) return;
    _blurSigma = value;
    markNeedsPaint();
  }

  final List<LayerHandle<ClipPathLayer>> _clips = [];
  final List<LayerHandle<BackdropFilterLayer>> _filters = [];

  @override
  bool get sizedByParent => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  RRect _rrect(Rect rect, double inset) {
    Radius r(Radius c) => Radius.circular(math.max(0.0, c.x - inset));
    return RRect.fromRectAndCorners(
      rect.deflate(inset),
      topLeft: r(_borderRadius.topLeft),
      topRight: r(_borderRadius.topRight),
      bottomLeft: r(_borderRadius.bottomLeft),
      bottomRight: r(_borderRadius.bottomRight),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final w = size.width, h = size.height;
    if (w < 2 * GlassRefraction._bezel || h < 2 * 4) return;
    final rect = offset & size;
    final c = rect.center;
    const edges = GlassRefraction._edges;
    final rings = edges.length - 1;
    while (_clips.length < rings + 1) {
      _clips.add(LayerHandle<ClipPathLayer>());
      _filters.add(LayerHandle<BackdropFilterLayer>());
    }
    for (var i = 0; i < rings; i++) {
      final outer = edges[i], inner = edges[i + 1];
      // Úzký prvek (tlačítko): vnitřní obrys nesmí přetéct přes střed.
      if (outer * 2 >= math.min(w, h)) break;
      final innerInset = math.min(inner, math.min(w, h) / 2 - 0.5);
      final ring = Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(_rrect(rect, outer))
        ..addRRect(_rrect(rect, innerInset));
      // Zvětšení kolem středu tak, aby se obsah u hrany posunul o `m`
      // dovnitř -- zvlášť v ose x a y (dlouhá lišta i kulaté tlačítko).
      final m = GlassRefraction._shift[i];
      final sx = (w / 2) / math.max(1.0, w / 2 - m);
      final sy = (h / 2) / math.max(1.0, h / 2 - m);
      final matrix = Matrix4.identity()
        ..translateByDouble(c.dx, c.dy, 0, 1)
        ..scaleByDouble(sx, sy, 1, 1)
        ..translateByDouble(-c.dx, -c.dy, 0, 1);
      final sigma = _blurSigma * GlassRefraction._blurShare[i];
      ui.ImageFilter filter = ui.ImageFilter.matrix(matrix.storage);
      if (sigma > 0.3) filter = ui.ImageFilter.compose(outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), inner: filter);
      if (_saturation != 1) filter = ui.ImageFilter.compose(outer: vibrancyColorFilter(saturation: _saturation), inner: filter);
      _clips[i].layer = context.pushClipPath(
        needsCompositing,
        Offset.zero,
        rect,
        ring,
        (context, _) {
          final layer = (_filters[i].layer ??= BackdropFilterLayer())..filter = filter;
          context.pushLayer(layer, (_, __) {}, Offset.zero);
        },
        oldLayer: _clips[i].layer,
      );
    }
    // Lem (1.2 px): jako v Apple Music -- světlá linka v barvě obsahu pod
    // sklem (modrá nad modrou, červená nad červenou), žádná bílá čára.
    final rim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(_rrect(rect, 0))
      ..addRRect(_rrect(rect, 1.2));
    final m0 = GlassRefraction._shift[0];
    final rimMatrix = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble((w / 2) / math.max(1.0, w / 2 - m0), (h / 2) / math.max(1.0, h / 2 - m0), 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    final rimFilter = ui.ImageFilter.compose(outer: _rimLight, inner: ui.ImageFilter.matrix(rimMatrix.storage));
    _clips[rings].layer = context.pushClipPath(
      needsCompositing,
      Offset.zero,
      rect,
      rim,
      (context, _) {
        final layer = (_filters[rings].layer ??= BackdropFilterLayer())..filter = rimFilter;
        context.pushLayer(layer, (_, __) {}, Offset.zero);
      },
      oldLayer: _clips[rings].layer,
    );
  }

  /// Zjasněný (ne bílý) obraz pod sklem -- lem má barvu toho, co je pod ním.
  static const ui.ColorFilter _rimLight = ui.ColorFilter.matrix(<double>[
    1.35, 0, 0, 0, 38, //
    0, 1.35, 0, 0, 38, //
    0, 0, 1.35, 0, 38, //
    0, 0, 0, 1, 0,
  ]);

  @override
  void dispose() {
    for (final h in _clips) {
      h.layer = null;
    }
    for (final h in _filters) {
      h.layer = null;
    }
    super.dispose();
  }
}
