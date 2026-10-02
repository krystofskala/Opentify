import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
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

  /// Zachytávání hlavní appky (`HomeShell`) -- pro panel přehrávače při
  /// vysouvání, který je samostatná trasa nad shellem.
  static LiquidCapture? get shell => _LiquidScopeState._shell;

  @override
  State<LiquidScope> createState() => _LiquidScopeState();
}

class _LiquidScopeState extends State<LiquidScope> {
  static LiquidCapture? _shell;
  final LiquidCapture _capture = LiquidCapture();

  @override
  void initState() {
    super.initState();
    _shell = _capture;
  }

  @override
  void dispose() {
    if (_shell == _capture) _shell = null;
    _capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LiquidScopeData(capture: _capture, child: widget.child);
}

/// Zachytávání pro skla MIMO `HomeShell` -- sheet fronty nad přehrávačem
/// je samostatná trasa, `LiquidScope` shellu nad ním není, a sklo tak
/// spadlo na obyčejné rozmazání bez lomu (živě nahlášeno). Přehrávač svůj
/// obsah registruje sem (`LiquidCaptureScope` + `LiquidSource.page`)
/// a sheet fronty si ho odsud bere.
final LiquidCapture playerLiquidCapture = LiquidCapture();

/// Jen pozadí appky, bez stránky -- pro ovládání v přehrávači (pod ním je
/// jen pozadí přehrávače = kopie pozadí appky). Kdyby bralo obsah panelu,
/// zachytávalo by samo sebe.
final LiquidCapture backgroundLiquidCapture = LiquidCapture();

/// Stránky kořenového navigátoru (shell i album/interpret otevřené nad
/// ním) -- pro panel přehrávače při vysouvání, ať lomí to, co je opravdu
/// pod ním, ne Domů schované pod otevřeným albem (živě nahlášeno).
final LiquidCapture routeLiquidCapture = LiquidCapture();

/// Dá podstromu konkrétní (sdílené) zachytávání, viz [playerLiquidCapture].
class LiquidCaptureScope extends StatelessWidget {
  const LiquidCaptureScope({super.key, required this.capture, required this.child});

  final LiquidCapture capture;
  final Widget child;

  @override
  Widget build(BuildContext context) => _LiquidScopeData(capture: capture, child: child);
}

/// Obsah uvnitř skla: vnořené sklo (tlačítko na liště, přepínač v menu)
/// nesmí lámat to, co je pod celým panelem -- vypadalo by jako díra.
class NoLiquidScope extends StatelessWidget {
  const NoLiquidScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _LiquidScopeData(capture: null, child: child);
}

class _LiquidScopeData extends InheritedWidget {
  const _LiquidScopeData({required this.capture, required super.child});

  final LiquidCapture? capture;

  @override
  bool updateShouldNotify(_LiquidScopeData old) => old.capture != capture;
}

/// Zachytávání obsahu pod skly jednoho `LiquidScope`.
class LiquidCapture {
  static RenderLiquidSource? _background;

  // Víc zdrojů (stránky nad sebou) -- bere se naposledy připojený, který
  // se zrovna kreslí (zakrytá/offstage stránka obrázek nevrátí).
  final List<RenderLiquidSource> _pages = [];
  final Set<RenderLiquidGlass> _glasses = {};
  // Obsah skel (text, vlnka...) -- při zachytávání se skryje taky, jinak by
  // sklo na okraji lámalo svůj vlastní obsah (duch vlnky u mini přehrávače).
  final Set<RenderLiquidHide> _hideables = {};
  ui.Image? _sharp;
  ui.Image? _blurred;
  Rect? _rect; // zachycený výřez (globálně, logické px)
  final List<ui.Image> _retired = [];
  bool _scheduled = false;
  Timer? _wait;
  DateTime _lastCapture = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  // Rezerva kolem skla -- při tahu sheetu se sklo posune dřív, než přijde
  // nový snímek; víc rezervy = méně často obyčejné rozmazání.
  static const double _margin = 72;
  // ~24 fps: pozadí se hýbe pomalu a obsah pod lištou je o snímek pozadu
  // tak jako tak. Dřív 32 ms a "moc brzy" si vynucovalo každý snímek
  // (scheduleFrame) -- appka pak kreslila 60 fps i v klidu.
  static const Duration _interval = Duration(milliseconds: 42);

  // Ostrý výřez stačí do 2x (Retina 3x je pod rozmazaným sklem k ničemu),
  // rozmazaný v polovičním rozlišení -- čte se přes UV, takže sedí dál.
  static const double _maxRatio = 2;

  bool get ready => _sharp != null && _rect != null;

  void _schedule() {
    if (_scheduled || _disposed || _glasses.isEmpty) return;
    _scheduled = true;
    final wait = _interval - DateTime.now().difference(_lastCapture);
    if (wait > Duration.zero) {
      // Počkat časovačem, ne vynucenými snímky.
      _wait = Timer(wait, _captureNextFrame);
    } else {
      _captureNextFrame();
    }
  }

  void _captureNextFrame() {
    _wait = null;
    if (_disposed) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed || _glasses.isEmpty) return;
      _lastCapture = DateTime.now();
      _capture();
    });
    SchedulerBinding.instance.scheduleFrame();
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
    final viewDpr = view.devicePixelRatio;
    final dpr = math.min(viewDpr, _maxRatio);
    final screen = Offset.zero & (view.physicalSize / viewDpr);
    final rect = union.inflate(_margin).intersect(screen);
    if (rect.isEmpty) return;
    // Skla tohohle zachytávání se na dobu snímku skryjí -- sklo ležící
    // přímo ve stránce (horní lišta alba) tak láme stránku pod sebou, ne
    // samo sebe (jinak by se obraz rozmazával do nekonečna).
    for (final g in _glasses) {
      g._hiddenForCapture(true);
    }
    for (final h in _hideables) {
      h._hiddenForCapture(true);
    }
    final ui.Image? bg;
    ui.Image? pg;
    Rect? pgRect;
    try {
      bg = bgSource.capture(rect, dpr)?.$1;
      for (final source in _pages.reversed) {
        final got = source.capture(rect, dpr);
        if (got != null) {
          (pg, pgRect) = got;
          break;
        }
      }
    } finally {
      for (final g in _glasses) {
        g._hiddenForCapture(false);
      }
      for (final h in _hideables) {
        h._hiddenForCapture(false);
      }
    }
    if (bg == null) {
      pg?.dispose();
      return;
    }
    // Složit pozadí + stránku do jednoho obrázku a z něj rozmazanou verzi
    // (skutečný Gauss na GPU -- stejné rozmazání jako běžné sklo).
    final w = bg.width, h = bg.height;
    final r1 = ui.PictureRecorder();
    final c1 = Canvas(r1);
    c1.drawImage(bg, Offset.zero, Paint());
    if (pg != null && pgRect != null) {
      // Stránka může pokrývat jen část výřezu (panel přehrávače začíná pod
      // horním okrajem, sheet fronty vytažený nahoru sahá nad něj) -- na její
      // skutečné místo, ne roztažená přes celý výřez (obal alba se jinak
      // natahoval a posouval s tahem sheetu, živě nahlášeno).
      final sx = w / rect.width, sy = h / rect.height;
      final dst = Rect.fromLTWH(
        (pgRect.left - rect.left) * sx,
        (pgRect.top - rect.top) * sy,
        pgRect.width * sx,
        pgRect.height * sy,
      );
      c1.drawImageRect(pg, Rect.fromLTWH(0, 0, pg.width.toDouble(), pg.height.toDouble()), dst, Paint());
    }
    final p1 = r1.endRecording();
    final sharp = p1.toImageSync(w, h);
    p1.dispose();
    bg.dispose();
    pg?.dispose();
    var sigma = 0.0;
    for (final g in _glasses) {
      sigma = math.max(sigma, g.blurSigma);
    }
    final bw = math.max(1, w ~/ 2), bh = math.max(1, h ~/ 2);
    final r2 = ui.PictureRecorder();
    final c2 = Canvas(r2);
    c2.scale(bw / w, bh / h);
    c2.drawImage(
      sharp,
      Offset.zero,
      // Zrcadlení, ne clamp: clamp na okraji výřezu natahoval krajní řádek
      // pixelů do pruhů (viditelné "čáry" při pohybu panelu).
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma * dpr, sigmaY: sigma * dpr, tileMode: TileMode.mirror),
    );
    final p2 = r2.endRecording();
    final blurred = p2.toImageSync(bw, bh);
    p2.dispose();
    // Staré obrázky ještě může používat rozpracovaný snímek -- uvolnit se zpožděním.
    if (_sharp != null) _retired.add(_sharp!);
    if (_blurred != null) _retired.add(_blurred!);
    while (_retired.length > 6) {
      _retired.removeAt(0).dispose();
    }
    _sharp = sharp;
    _blurred = blurred;
    _rect = rect;
    for (final g in _glasses) {
      g.markNeedsPaint();
    }
  }

  void dispose() {
    _disposed = true;
    _wait?.cancel();
    _sharp?.dispose();
    _blurred?.dispose();
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
      RenderLiquidSource(_kind == _SourceKind.page ? LiquidScope.maybeOf(context) : null, isPage: _kind == _SourceKind.page);

  @override
  void updateRenderObject(BuildContext context, RenderLiquidSource renderObject) {
    renderObject.scope = _kind == _SourceKind.page ? LiquidScope.maybeOf(context) : null;
  }
}

class RenderLiquidSource extends RenderRepaintBoundary {
  RenderLiquidSource(this._scope, {this.isPage = false});

  /// Stránka bez zachytávání nad sebou se neregistruje nikam (ne jako
  /// globální pozadí).
  final bool isPage;

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
      if (isPage) return;
      LiquidCapture._background = this;
    } else {
      scope._pages
        ..remove(this)
        ..add(this);
    }
  }

  void _unregister() {
    final scope = _scope;
    if (scope == null) {
      if (!isPage && LiquidCapture._background == this) LiquidCapture._background = null;
    } else {
      scope._pages.remove(this);
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

  /// Výřez `global` (logické px) jako obrázek + jaká část `global` to
  /// skutečně je (globálně), nebo `null`.
  (ui.Image, Rect)? capture(Rect global, double pixelRatio) {
    final offsetLayer = layer as OffsetLayer?;
    // Nekreslená (offstage/zakrytá) stránka má ve vrstvě starý obraz --
    // nebrat ho.
    if (offsetLayer == null || !offsetLayer.attached || !attached || !hasSize) return null;
    final origin = localToGlobal(Offset.zero);
    final local = global.shift(-origin).intersect(Offset.zero & size);
    if (local.isEmpty) return null;
    try {
      return (offsetLayer.toImageSync(local, pixelRatio: pixelRatio), local.shift(origin));
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
    _settleTimer?.cancel();
    super.detach();
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  bool get sizedByParent => true;

  // Vlastní vrstva (průhlednost), aby šlo sklo při zachytávání na okamžik
  // skrýt, viz `LiquidCapture._capture`.
  @override
  bool get alwaysNeedsCompositing => true;

  void _hiddenForCapture(bool hidden) {
    final l = layer;
    if (l is OpacityLayer) l.alpha = hidden ? 0 : 255;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      layer = null;
      return;
    }
    layer = context.pushOpacity(offset, 255, _paintGlass, oldLayer: layer as OpacityLayer?);
  }

  // Rychlý pohyb/změna velikosti skla: na webu je zachycený obsah o snímek
  // (a interval zachytávání) pozadu, lom by "ujížděl" -- po dobu pohybu
  // obyčejné rozmazání, lom až ~150 ms po zastavení (živě nahlášeno).
  // V nativní appce (Impeller, bez zpoždění) se dá vypnout.
  static const bool _calmWhileFast = kIsWeb;
  // Hystereze podle RYCHLOSTI (px/s), ne posunu za snímek -- pomalý tah
  // prstem má lom nechat (dřív se vypínal i při něm a sklo blikalo).
  static const double _fastSpeed = 1600;
  static const double _calmSpeed = 700;
  static const Duration _settle = Duration(milliseconds: 140);
  // Přechod lom <-> rozmazání se prolíná, ne přepíná.
  static const double _fadeSeconds = 0.16;
  Rect? _prevRect;
  int _prevAt = 0;
  bool _fast = false;
  DateTime _calmSince = DateTime.fromMillisecondsSinceEpoch(0);
  double _mix = 1; // 1 = lom, 0 = obyčejné rozmazání
  int _mixAt = 0;
  Timer? _settleTimer;

  void _updateMotion(Rect now) {
    final t = DateTime.now().microsecondsSinceEpoch;
    final prev = _prevRect;
    final dt = (t - _prevAt) / 1e6;
    _prevRect = now;
    _prevAt = t;
    if (!_calmWhileFast) return;
    if (prev != null && dt > 0 && dt < 0.25) {
      final moved = (now.topLeft - prev.topLeft).distance +
          (now.size.width - prev.size.width).abs() +
          (now.size.height - prev.size.height).abs();
      final speed = moved / dt;
      if (speed > _fastSpeed) {
        _fast = true;
        _calmSince = DateTime.now();
      } else if (speed > _calmSpeed) {
        _calmSince = DateTime.now();
      }
    }
    if (_fast && DateTime.now().difference(_calmSince) > _settle) _fast = false;
    // Plynulý posun `_mix` k cíli.
    final target = _fast ? 0.0 : 1.0;
    final mixDt = _mixAt == 0 ? 0.0 : (t - _mixAt) / 1e6;
    _mixAt = t;
    final step = (mixDt / _fadeSeconds).clamp(0.0, 1.0);
    _mix = target > _mix ? math.min(target, _mix + step) : math.max(target, _mix - step);
    if (_fast || _mix != target) {
      // Dokud se nepřelije / nevrátí, překreslovat (i když se sklo už nehýbe).
      _settleTimer?.cancel();
      _settleTimer = Timer(const Duration(milliseconds: 16), () {
        if (attached) markNeedsPaint();
      });
    }
  }

  void _paintBlurFallback(PaintingContext context, Offset offset, RRect rrect, double opacity) {
    void paintBlur(PaintingContext ctx, Offset off) {
      ctx.pushClipRRect(needsCompositing, off, Offset.zero & size, rrect.shift(-offset), (c2, o2) {
        c2.pushLayer(
          BackdropFilterLayer(filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma)),
          (c, o) => c.canvas.drawRect(o & size, Paint()..color = fill),
          o2,
        );
      });
    }

    if (opacity >= 0.999) {
      paintBlur(context, offset);
    } else {
      context.pushOpacity(offset, (opacity * 255).round(), (ctx, off) => paintBlur(ctx, off));
    }
  }

  void _paintGlass(PaintingContext context, Offset offset) {
    globalRect = localToGlobal(Offset.zero) & size;
    _updateMotion(globalRect!);
    _capture._schedule();
    final rrect = RRect.fromRectAndRadius(offset & size, Radius.circular(math.min(radius, size.shortestSide / 2)));
    final mix = _mix;
    if (mix < 1) _paintBlurFallback(context, offset, rrect, 1);
    if (mix <= 0.001) return;
    final canvas = context.canvas;
    final program = _program;
    final sharp = _capture._sharp, blurred = _capture._blurred, rect = _capture._rect;
    // Sklo vyjelo mimo zachycený výřez (rychlý tah -- obraz je o snímek
    // pozadu): shader by za okrajem opakoval krajní pixely = pruhy. Do
    // dalšího zachycení obyčejné rozmazání.
    final g = globalRect!;
    final outside = rect != null &&
        (g.left < rect.left - 0.5 || g.top < rect.top - 0.5 || g.right > rect.right + 0.5 || g.bottom > rect.bottom + 0.5);
    if (outside) {
      if (mix >= 1) _paintBlurFallback(context, offset, rrect, 1);
      if (_calmWhileFast) {
        // Zpátky k lomu plynule (prolnutí v `_updateMotion`), ne skokem.
        _fast = true;
        _calmSince = DateTime.now();
        _mix = 0;
      }
      return;
    }
    if (program == null || sharp == null || blurred == null || rect == null) {
      // První snímek ještě není zachycený: obyčejné rozmazání se stejnou
      // výplní (dřív 55% šedá plocha -- sheet vyjel tmavě šedý a čiré sklo
      // přehrávače se na okamžik "zatónovalo", živě nahlášeno).
      if (mix >= 1) _paintBlurFallback(context, offset, rrect, 1);
      return;
    }
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
    shader.setImageSampler(0, sharp);
    shader.setImageSampler(1, blurred);
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    // Při prolínání s obyčejným rozmazáním průhlednost podle `mix`.
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader..color = Color.fromRGBO(0, 0, 0, mix));
    canvas.restore();
  }
}


/// Obsah skla, který se při zachytávání na okamžik skryje (viz
/// `LiquidCapture._hideables`).
class LiquidHide extends SingleChildRenderObjectWidget {
  const LiquidHide({super.key, required this.capture, super.child});

  final LiquidCapture capture;

  @override
  RenderLiquidHide createRenderObject(BuildContext context) => RenderLiquidHide(capture);

  @override
  void updateRenderObject(BuildContext context, RenderLiquidHide renderObject) => renderObject.capture = capture;
}

class RenderLiquidHide extends RenderProxyBox {
  RenderLiquidHide(this._capture);

  LiquidCapture _capture;
  set capture(LiquidCapture value) {
    if (value == _capture) return;
    if (attached) _capture._hideables.remove(this);
    _capture = value;
    if (attached) _capture._hideables.add(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _capture._hideables.add(this);
  }

  @override
  void detach() {
    _capture._hideables.remove(this);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  void _hiddenForCapture(bool hidden) {
    final l = layer;
    if (l is OpacityLayer) l.alpha = hidden ? 0 : 255;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    layer = context.pushOpacity(offset, 255, super.paint, oldLayer: layer as OpacityLayer?);
  }
}
