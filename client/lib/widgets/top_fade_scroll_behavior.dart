import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Obsah svislých seznamů se u horní hrany postupně rozplyne do pozadí, jak
/// odjíždí pod lištu -- místo šedého skleněného pruhu, který se dřív objevil
/// za nadpisem při scrollu (živě nahlášeno: "zašedlé/zablokované nahoře").
/// V klidu (nahoře) se nic nemaže; rozplynutí naběhne s prvními pixely scrollu.
class TopFadeScrollBehavior extends MaterialScrollBehavior {
  const TopFadeScrollBehavior();

  /// Žádné posuvníky (na PC je Material ukazuje u každého seznamu a
  /// rozbíjely dojem skla -- živě nahlášeno). Scroll kolečkem/tažením dál jde.
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    final base = super.buildOverscrollIndicator(context, child, details);
    if (details.direction != AxisDirection.down) return base;
    return _TopFade(child: base);
  }
}

/// Render objekt místo `ListenableBuilder` + `ShaderMask`: dřív se při
/// každém pixelu scrollu přestavoval widget a na hraně 0 se měnil tvar
/// stromu (s maskou / bez ní), takže se celý obsah seznamu znovu připojoval.
/// Teď se jen překreslí, a to jen dokud se mění průhlednost (prvních 28 px).
class _TopFade extends SingleChildRenderObjectWidget {
  const _TopFade({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTopFade(Scrollable.maybeOf(context)?.position);

  @override
  void updateRenderObject(BuildContext context, _RenderTopFade renderObject) {
    renderObject.position = Scrollable.maybeOf(context)?.position;
  }
}

class _RenderTopFade extends RenderProxyBox {
  _RenderTopFade(this._position);

  static const double _fade = 28;

  ScrollPosition? _position;
  double _t = 0;

  set position(ScrollPosition? value) {
    if (value == _position) return;
    if (attached) _position?.removeListener(_onScroll);
    _position = value;
    if (attached) {
      value?.addListener(_onScroll);
      _onScroll();
    }
  }

  void _onScroll() {
    final p = _position;
    final pixels = p != null && p.hasPixels ? p.pixels : 0.0;
    final t = (pixels / _fade).clamp(0.0, 1.0);
    if (t == _t) return;
    _t = t;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position?.addListener(_onScroll);
    _onScroll();
  }

  @override
  void detach() {
    _position?.removeListener(_onScroll);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (_t <= 0) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    final rect = Offset.zero & size;
    final stop = size.height <= 0 ? 1.0 : (_fade / size.height).clamp(0.0, 1.0);
    final mask = (layer as ShaderMaskLayer?) ?? ShaderMaskLayer();
    mask
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black.withValues(alpha: 1 - _t), Colors.black],
        stops: [0, stop],
      ).createShader(rect)
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    layer = mask;
    context.pushLayer(mask, super.paint, offset);
  }
}
