import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Liquid Glass se skutečným plynulým lomem i na webu (TEST, Profil ›
/// Vzhled › "Lom skla (test)"). Stejný princip jako liquid-glass.ybouane.com:
/// obsah pod sklem se po každém snímku zachytí do obrázku (jen úzký výřez
/// kolem skla) a sklo ho vykreslí shaderem `shaders/liquid_glass.frag`
/// (Snell na zaoblené hraně, rozmazání středu, lem v barvě obsahu).
///
/// Flutter web neumí shader přímo na pozadí (`ImageFilter.shader` je jen
/// pro Impeller), ale shader jako výplň (`Paint.shader`) nad zachyceným
/// obrázkem ano. Snímek je o jeden snímek pozadu (zachytává se po
/// vykreslení -- zachycení uprostřed kreslení by rozbilo znovupoužití vrstev).
///
/// Zdroje: pozadí appky (`LiquidSource.background`, globální) a obsah
/// stránky pod lištami (`LiquidSource.page` uvnitř `LiquidScope`). Sklo bez
/// `LiquidScope` nad sebou (detaily alb/interpretů) kreslí běžné sklo.
class LiquidScope extends StatefulWidget {
  const LiquidScope({super.key, required this.child});

  final Widget child;

  static LiquidCapture? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LiquidScopeData>()?.capture;

  @override
  State<LiquidScope> createState() => _LiquidScopeState();
}

class _LiquidScopeState extends State<LiquidScope> {
  final LiquidCapture _capture = LiquidCapture();

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LiquidScopeData(capture: _capture, child: widget.child);
}

class _LiquidScopeData extends InheritedWidget {
  const _LiquidScopeData({required this.capture, required super.child});

  final LiquidCapture capture;

  @override
  bool updateShouldNotify(_LiquidScopeData old) => old.capture != capture;
}

/// Zachytávání obsahu pod skly jednoho `LiquidScope`.
class LiquidCapture {
  static RenderLiquidSource? _background;

  RenderLiquidSource? _page;
  final Set<RenderLiquidGlass> _glasses = {};
  ui.Image? _bg;
  ui.Image? _pg;
  Rect? _rect; // zachycený výřez (globálně, logické px)
  final List<ui.Image> _retired = [];
  bool _scheduled = false;
  Duration _lastCapture = Duration.zero;
  bool _disposed = false;

  static const double _margin = 40;
  static const Duration _interval = Duration(milliseconds: 32);

  bool get ready => _bg != null && _rect != null;

  void _schedule() {
    if (_scheduled || _disposed || _glasses.isEmpty) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
      _scheduled = false;
      if (_disposed || _glasses.isEmpty) return;
      if (timeStamp - _lastCapture < _interval) {
        // Příliš brzy -- zkusit v dalším snímku (pozadí jede ~30 fps).
        SchedulerBinding.instance.scheduleFrame();
        _schedule();
        return;
      }
      _lastCapture = timeStamp;
      _capture();
    });
  }

  void _capture() {
    Rect? union;
    for (final g in _glasses) {
      final r = g.globalRect;
      if (r == null) continue;
      union = union == null ? r : union.expandToInclude(r);
    }
    final bgSource = _background;
    if (union == null || bgSource == null) return;
    final view = ui.PlatformDispatcher.instance.views.first;
    final dpr = view.devicePixelRatio;
    final screen = Offset.zero & (view.physicalSize / dpr);
    final rect = union.inflate(_margin).intersect(screen);
    if (rect.isEmpty) return;
    final bg = bgSource.capture(rect, dpr);
    final pg = _page?.capture(rect, dpr);
    if (bg == null) {
      pg?.dispose();
      return;
    }
    // Staré obrázky ještě může používat rozpracovaný snímek -- uvolnit se zpožděním.
    if (_bg != null) _retired.add(_bg!);
    if (_pg != null) _retired.add(_pg!);
    while (_retired.length > 6) {
      _retired.removeAt(0).dispose();
    }
    _bg = bg;
    _pg = pg;
    _rect = rect;
    for (final g in _glasses) {
      g.markNeedsPaint();
    }
  }

  void dispose() {
    _disposed = true;
    _bg?.dispose();
    _pg?.dispose();
    for (final i in _retired) {
      i.dispose();
    }
    _retired.clear();
  }
}

enum _SourceKind { background, page }

/// Hranice vrstvy, kterou jde zachytit pro sklo (`RepaintBoundary` navíc
/// umí vyříznout obrázek libovolného výřezu).
class LiquidSource extends SingleChildRenderObjectWidget {
  const LiquidSource.background({super.key, super.child}) : _kind = _SourceKind.background;
  const LiquidSource.page({super.key, super.child}) : _kind = _SourceKind.page;

  final _SourceKind _kind;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderLiquidSource(_kind == _SourceKind.page ? LiquidScope.maybeOf(context) : null);

  @override
  void updateRenderObject(BuildContext context, RenderLiquidSource renderObject) {
    renderObject.scope = _kind == _SourceKind.page ? LiquidScope.maybeOf(context) : null;
  }
}

class RenderLiquidSource extends RenderRepaintBoundary {
  RenderLiquidSource(this._scope);

  LiquidCapture? _scope;
  set scope(LiquidCapture? value) {
    if (value == _scope) return;
    if (attached) _unregister();
    _scope = value;
    if (attached) _register();
  }

  void _register() {
    final scope = _scope;
    if (scope == null) {
      LiquidCapture._background = this;
    } else {
      scope._page = this;
    }
  }

  void _unregister() {
    final scope = _scope;
    if (scope == null) {
      if (LiquidCapture._background == this) LiquidCapture._background = null;
    } else if (scope._page == this) {
      scope._page = null;
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }

  /// Výřez `global` (logické px) jako obrázek, nebo `null`.
  ui.Image? capture(Rect global, double pixelRatio) {
    final offsetLayer = layer as OffsetLayer?;
    if (offsetLayer == null || !attached || !hasSize) return null;
    final origin = localToGlobal(Offset.zero);
    final local = global.shift(-origin).intersect(Offset.zero & size);
    if (local.isEmpty) return null;
    try {
      return offsetLayer.toImageSync(local, pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }
}

/// Plocha skla s lomem. Kreslí i výplň skla (`fill`); dokud není první
/// snímek zachycený, jen výplň.
class LiquidGlass extends LeafRenderObjectWidget {
  const LiquidGlass({
    super.key,
    required this.capture,
    required this.radius,
    required this.blurSigma,
    required this.fill,
    required this.saturation,
  });

  final LiquidCapture capture;
  final double radius;
  final double blurSigma;
  final Color fill;
  final double saturation;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderLiquidGlass(
        capture: capture,
        radius: radius,
        blurSigma: blurSigma,
        fill: fill,
        saturation: saturation,
      );

  @override
  void updateRenderObject(BuildContext context, RenderLiquidGlass renderObject) {
    renderObject
      ..capture = capture
      ..radius = radius
      ..blurSigma = blurSigma
      ..fill = fill
      ..saturation = saturation;
  }
}

class RenderLiquidGlass extends RenderBox {
  RenderLiquidGlass({
    required LiquidCapture capture,
    required this.radius,
    required this.blurSigma,
    required this.fill,
    required this.saturation,
  }) : _capture = capture {
    _loadProgram();
  }

  // Schválené hodnoty z náhledu "Lom skla".
  static const double _bezel = 22;
  static const double _strength = 25;
  static ui.FragmentProgram? _program;
  static Future<void>? _loading;
  static final double _norm = _snellMax();

  static double _snellMax() {
    double f(double x) => math.pow(math.max(0.0, 1 - math.pow(1 - x, 4)), 0.25).toDouble();
    var max = 0.0;
    for (var i = 1; i <= 256; i++) {
      final x = i / 256;
      const e = 0.002;
      final slope = (f(math.min(1.0, x + e)) - f(math.max(0.0, x - e))) / (2 * e);
      final t1 = math.atan(slope);
      final t2 = math.asin(math.sin(t1) / 1.5);
      max = math.max(max, (0.8 + f(x)) * math.tan(t1 - t2));
    }
    return max;
  }

  void _loadProgram() {
    if (_program != null) return;
    _loading ??= ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag').then<void>((p) {
      _program = p;
    }, onError: (Object e) {
      debugPrint('LiquidGlass: shader se nenačetl ($e)');
    });
    unawaited(_loading!.then((_) {
      if (attached) markNeedsPaint();
    }));
  }

  LiquidCapture _capture;
  set capture(LiquidCapture value) {
    if (value == _capture) return;
    if (attached) _capture._glasses.remove(this);
    _capture = value;
    if (attached) _capture._glasses.add(this);
    markNeedsPaint();
  }

  double radius;
  double blurSigma;
  Color fill;
  double saturation;
  ui.FragmentShader? _shader;

  /// Poloha na obrazovce (logické px) z posledního kreslení.
  Rect? globalRect;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _capture._glasses.add(this);
  }

  @override
  void detach() {
    _capture._glasses.remove(this);
    super.detach();
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    globalRect = localToGlobal(Offset.zero) & size;
    _capture._schedule();
    final canvas = context.canvas;
    final rrect = RRect.fromRectAndRadius(offset & size, Radius.circular(math.min(radius, size.shortestSide / 2)));
    final program = _program;
    final bg = _capture._bg, rect = _capture._rect;
    if (program == null || bg == null || rect == null) {
      canvas.drawRRect(rrect, Paint()..color = fill.withValues(alpha: math.max(fill.a, 0.55)));
      return;
    }
    final pg = _capture._pg;
    // Nová instance na každý snímek (jako pozadí) -- sdílená instance
    // s přepisovanými uniformy v CanvasKitu rozbíjela obrázky.
    _shader?.dispose();
    final shader = program.fragmentShader();
    _shader = shader;
    final origin = globalRect!.topLeft - rect.topLeft;
    final view = ui.PlatformDispatcher.instance.views.first;
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    f(size.width);
    f(size.height);
    f(origin.dx);
    f(origin.dy);
    f(rect.width);
    f(rect.height);
    f(radius);
    f(_bezel);
    f(_strength);
    f(blurSigma);
    f(fill.r);
    f(fill.g);
    f(fill.b);
    f(fill.a);
    f(saturation);
    f(_norm);
    f(view.devicePixelRatio);
    shader.setImageSampler(0, bg);
    shader.setImageSampler(1, pg ?? bg);
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    canvas.restore();
  }
}
