import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lem skla jako v Apple Music: tenká (1.2 px) světlá linka v barvě obsahu
/// pod sklem -- zjasněný obraz toho, co je pod hranou (modrá nad modrou,
/// červená nad červenou), žádná bílá čára.
///
/// Skutečný lom (obraz se u hrany plynule ohýbá) na webu nejde: Flutter web
/// neumí `ImageFilter.shader` ("only supported with Impeller"), a lom
/// skládaný ze soustředných prstenců se zvětšením dělal viditelné schody
/// (živě nahlášeno). Plynulý lom přijde v nativní appce (Impeller, jeden
/// shader na prvek podle schváleného náhledu "Lom skla").
class GlassRim extends LeafRenderObjectWidget {
  const GlassRim({super.key, required this.borderRadius});

  final BorderRadius borderRadius;

  /// Šířka lemu -- vnitřek skla (rozmazání) začíná za ním.
  static const double width = 1.2;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderGlassRim(borderRadius: borderRadius);

  @override
  void updateRenderObject(BuildContext context, RenderGlassRim renderObject) {
    renderObject.borderRadius = borderRadius;
  }
}

class RenderGlassRim extends RenderBox {
  RenderGlassRim({required BorderRadius borderRadius}) : _borderRadius = borderRadius;

  BorderRadius _borderRadius;
  set borderRadius(BorderRadius value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  final LayerHandle<ClipPathLayer> _clip = LayerHandle<ClipPathLayer>();
  final LayerHandle<BackdropFilterLayer> _filter = LayerHandle<BackdropFilterLayer>();

  /// Zjasněný (ne bílý) obraz pod sklem.
  static const ui.ColorFilter _rimLight = ui.ColorFilter.matrix(<double>[
    1.35, 0, 0, 0, 38, //
    0, 1.35, 0, 0, 38, //
    0, 0, 1.35, 0, 38, //
    0, 0, 0, 1, 0,
  ]);

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
    if (size.shortestSide < 4) return;
    final rect = offset & size;
    final rim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(_rrect(rect, 0))
      ..addRRect(_rrect(rect, GlassRim.width));
    _clip.layer = context.pushClipPath(
      needsCompositing,
      Offset.zero,
      rect,
      rim,
      (context, _) {
        final layer = (_filter.layer ??= BackdropFilterLayer())..filter = _rimLight;
        context.pushLayer(layer, (_, __) {}, Offset.zero);
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    _filter.layer = null;
    super.dispose();
  }
}
