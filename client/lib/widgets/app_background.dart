import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/reduced_motion.dart';

/// Globální pozadí appky -- tekuté zrnité gradienty (reference: "50 Grainy
/// Gradients", generativní Figma gradienty) v jednom fragment shaderu
/// (`shaders/chroma_grain.frag`): 5 měkkých barevných ploch na pomalých
/// drahách, tekuté pokřivení prostoru, lesklé pruhy a silné filmové zrno.
///
/// Barvy podle uživatele: dokud nic nehrálo ani se neotevřelo žádné album,
/// je pozadí pestré (`selectedAccent == null`); jakmile je nějaká barva
/// "vybraná", je vždy monochromatické v jejím odstínu. Přehrávač
/// (`NowPlayingScreen`, `PlayerBar`) má vlastní plnou výplň -- tohle pozadí
/// pod ním není vidět a animace se po dobu jeho otevření zastaví (`hidden`).
class AppBackground extends StatefulWidget {
  const AppBackground({
    super.key,
    required this.selectedAccent,
    required this.brightness,
    required this.isPlaying,
    required this.hidden,
    required this.child,
  });

  final Color? selectedAccent;
  final Brightness brightness;
  final bool isPlaying;
  final bool hidden;
  final Widget child;

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground> with SingleTickerProviderStateMixin {
  static final Future<ui.FragmentProgram?> _program = _loadProgram();
  static bool _loggedPath = false;

  static Future<ui.FragmentProgram?> _loadProgram() async {
    // Shader jen na vyžádání (`--dart-define=BG_SHADER=true`): v CanvasKitu
    // (Flutter 3.44 web) při plynulém překreslování černaly obaly alb.
    if (!const bool.fromEnvironment('BG_SHADER', defaultValue: false)) return null;
    try {
      return await ui.FragmentProgram.fromAsset('shaders/chroma_grain.frag');
    } catch (e) {
      debugPrint('AppBackground: shader se nenačetl ($e) -- záložní gradient');
      return null;
    }
  }

  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch()..start();
  final ValueNotifier<int> _frame = ValueNotifier(0);
  ui.FragmentProgram? _programReady;
  ui.FragmentShader? _lastShader;

  // Paleta: 6 slotů, přechod v OKLab se zpožděním 60 ms mezi sloty.
  late List<_Lab> _from;
  late List<_Lab> _to;
  double _tweenStart = -10;

  double _phase = 0;
  double _speed = 1;
  double _boost = 0;
  double _boostTarget = 0;
  double _bloom = 0;
  double _lastPaintAt = 0;
  double _lastActivityAt = 0;
  double _lastScrollAt = 0;
  double _pixelRatio = 1;
  bool _reducedMotion = false;

  static const _tweenSeconds = 1.2;
  static const _staggerSeconds = 0.06;

  double get _now => _clock.elapsedMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    final palette = _paletteFor(widget.selectedAccent, widget.brightness).map(_Lab.fromColor).toList();
    _from = palette;
    _to = palette;
    _ticker = createTicker(_onTick);
    _program.then((program) {
      if (!mounted) return;
      if (!_loggedPath) {
        _loggedPath = true;
        debugPrint(program != null
            ? 'AppBackground: fragment shader aktivní'
            : 'AppBackground: canvas gradient + zrno');
      }
      if (program != null) {
        setState(() => _programReady = program);
      }
    });
    _wake();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    _reducedMotion = MediaQuery.disableAnimationsOf(context) || systemPrefersReducedMotion();
  }

  @override
  void didUpdateWidget(AppBackground old) {
    super.didUpdateWidget(old);
    if (old.selectedAccent != widget.selectedAccent || old.brightness != widget.brightness) {
      _startTween(_paletteFor(widget.selectedAccent, widget.brightness));
      if (old.selectedAccent != null && widget.selectedAccent != null && !_reducedMotion) _bloom = 1;
    }
    if (old.hidden != widget.hidden || old.isPlaying != widget.isPlaying) _wake();
  }

  void _startTween(List<Color> palette) {
    final now = _now;
    _from = List.generate(6, (i) => _slotAt(i, now));
    _to = palette.map(_Lab.fromColor).toList();
    _tweenStart = now;
    _wake();
  }

  double get _tweenDuration => _reducedMotion ? 0.4 : _tweenSeconds;
  double get _stagger => _reducedMotion ? 0 : _staggerSeconds;
  bool _tweening(double now) => now < _tweenStart + _tweenDuration + _stagger * 5;

  _Lab _slotAt(int i, double now) {
    final raw = ((now - _tweenStart - i * _stagger) / _tweenDuration).clamp(0.0, 1.0);
    final t = Curves.easeInOutCubic.transform(raw);
    return _Lab.lerp(_from[i], _to[i], t);
  }

  void _wake() {
    _lastActivityAt = _now;
    if (widget.hidden) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (!_ticker.isActive) {
      _lastPaintAt = _now;
      _ticker.start();
    }
  }

  void _onTick(Duration _) {
    final now = _now;
    final dt = now - _lastPaintAt;
    if (dt < 1 / 30 - 0.002) return; // 30 fps strop
    _lastPaintAt = now;
    final step = math.min(dt, 0.1);

    if (!_reducedMotion) {
      // Klid ~60 s na smyčku, při přehrávání ~20 s (náběh ~1.5 s).
      final targetSpeed = widget.isPlaying ? 3.0 : 1.0;
      _speed += (targetSpeed - _speed) * (1 - math.exp(-step / 0.5));
      final tau = _boostTarget > _boost ? 0.12 : 0.8;
      _boost += (_boostTarget - _boost) * (1 - math.exp(-step / tau));
      if (now - _lastScrollAt > 0.12) _boostTarget *= math.exp(-step / 0.15);
      _bloom *= math.exp(-step / 0.2);
      _phase = (_phase + step * _speed * (1 + 3 * _boost)) % 600;
    }
    _frame.value++;

    final busy = widget.isPlaying || _boost > 0.01 || _boostTarget > 0.01 || _bloom > 0.01 || _tweening(now);
    final animating = !_reducedMotion && busy;
    if (animating || _tweening(now)) {
      _lastActivityAt = now;
    } else if (now - _lastActivityAt > 3) {
      _ticker.stop();
    }
    if (_reducedMotion && !_tweening(now)) _ticker.stop();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final delta = (notification.scrollDelta ?? 0).abs();
      final now = _now;
      final dt = math.max(now - _lastScrollAt, 1 / 60);
      _lastScrollAt = now;
      final velocity = delta / dt;
      _boostTarget = math.max(_boostTarget, (velocity / 2000).clamp(0.0, 1.0));
      if (!_reducedMotion) _wake();
    }
    return false;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    _lastShader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final painter = _programReady != null
        ? _ShaderPainter(state: this, repaint: _frame)
        : _FallbackPainter(state: this, repaint: _frame);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Každá vrstva přímé dítě `Stack`u -- `Positioned` uvnitř
          // `RepaintBoundary` dřív shazoval release build.
          RepaintBoundary(child: IgnorePointer(child: CustomPaint(painter: painter))),
          widget.child,
        ],
      ),
    );
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter({required this.state, required Listenable repaint}) : super(repaint: repaint);

  final _AppBackgroundState state;

  @override
  void paint(Canvas canvas, Size size) {
    final program = state._programReady;
    if (program == null || size.isEmpty) return;
    // Nová instance na každý snímek (předchozí se uvolní) -- přepisování
    // uniformů jedné sdílené instance v CanvasKitu rozbíjelo nahrávání
    // obrázků na GPU (obaly alb se vykreslovaly černě).
    state._lastShader?.dispose();
    final shader = program.fragmentShader();
    state._lastShader = shader;
    final now = state._now;
    final isDark = state.widget.brightness == Brightness.dark;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, state._phase)
      ..setFloat(3, 0.55 * (1 + 0.3 * state._boost) + 0.15 * state._bloom)
      ..setFloat(4, isDark ? 0.14 : 0.09)
      ..setFloat(5, state._pixelRatio)
      ..setFloat(6, state._bloom)
      ..setFloat(7, isDark ? 1 : 0);
    for (var i = 0; i < 6; i++) {
      final c = state._slotAt(i, now).toColor();
      shader
        ..setFloat(8 + i * 3, c.r)
        ..setFloat(9 + i * 3, c.g)
        ..setFloat(10 + i * 3, c.b);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _ShaderPainter old) => true;
}

/// Výchozí vykreslování: měkké barevné plochy jako nativní radiální
/// gradienty (levné na GPU) -- kulaté "bokeh" záře i protáhlé, pomalu se
/// otáčející "tekuté šmouhy" -- a přes ně husté filmové zrno předpočítané
/// jednou v rozlišení zařízení. Fragment shader je jen volitelný
/// (`BG_SHADER=true`): v CanvasKitu při plynulém překreslování rozbíjel
/// vykreslování obrázků (obaly alb černaly).
class _FallbackPainter extends CustomPainter {
  _FallbackPainter({required this.state, required Listenable repaint}) : super(repaint: repaint);

  final _AppBackgroundState state;
  static ui.Image? _grain;
  static String? _grainKey;

  // [slot, rychlost x, rychlost y, fáze, velikost, protažení, rychlost rotace]
  static const _layers = <List<double>>[
    [1, 10, 7, 0.0, 0.95, 1.0, 0],
    [2, 6, 11, 2.1, 0.75, 2.6, 3],
    [3, 13, 9, 4.2, 0.62, 1.0, 0],
    [5, 8, 14, 1.3, 0.55, 3.2, -4],
    [2, 9, 5, 3.3, 0.45, 1.0, 0],
    [4, 11, 6, 5.4, 0.30, 2.2, 5],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final now = state._now;
    final dark = state.widget.brightness == Brightness.dark;
    final colors = List.generate(6, (i) => state._slotAt(i, now).toColor());
    canvas.drawRect(Offset.zero & size, Paint()..color = colors[0]);

    final t = state._phase * 2 * math.pi / 600;
    final bloom = state._bloom;
    for (final l in _layers) {
      final color = colors[l[0].toInt()];
      final center = Offset(
        size.width * (0.5 + 0.42 * math.sin(t * l[1] + l[3])),
        size.height * (0.5 + 0.40 * math.cos(t * l[2] + l[3] * 1.7)),
      );
      final radius = size.shortestSide * l[4] * (1 + 0.12 * bloom);
      final stretch = l[5] * (1 + 0.15 * math.sin(t * 7 + l[3]));
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(l[3] + t * l[6]);
      canvas.scale(stretch, 1 / math.sqrt(stretch));
      canvas.drawCircle(
        Offset.zero,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            radius,
            [color.withValues(alpha: 0.95), color.withValues(alpha: 0.45), color.withValues(alpha: 0)],
            const [0, 0.45, 1],
          ),
      );
      canvas.restore();
    }

    if (dark) {
      final center = size.center(Offset.zero);
      final r = size.longestSide * 0.75;
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            r,
            [Colors.transparent, Colors.black.withValues(alpha: 0.35)],
            const [0.45, 1],
          ),
      );
    }

    final dpr = state._pixelRatio;
    final key = '${size.width.round()}x${size.height.round()}@$dpr/$dark';
    if (_grain == null || _grainKey != key) {
      _grain?.dispose();
      _grainKey = key;
      _grain = _buildGrain(size, dpr, dark);
    }
    canvas.drawImageRect(
      _grain!,
      Rect.fromLTWH(0, 0, _grain!.width.toDouble(), _grain!.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  /// Zrno ve fyzických pixelech (buňky ~1.6 px), trojúhelníkové rozdělení
  /// jasu, jednou za velikost okna -- každý snímek pak jen jedno vykreslení
  /// textury. Tmavý režim silnější (±14 %), světlý jemnější (±9 %).
  static ui.Image _buildGrain(Size size, double dpr, bool dark) {
    const cell = 1.6;
    final cols = (size.width * dpr / cell).ceil();
    final rows = (size.height * dpr / cell).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final random = math.Random(7);
    final strength = dark ? 0.14 : 0.09;
    final buckets = List.generate(6, (_) => <double>[]);
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final g = random.nextDouble() + random.nextDouble() - 1; // -1..1
        if (g.abs() < 0.15) continue;
        final bucket = (g.abs() * 3).floor().clamp(0, 2) + (g > 0 ? 0 : 3);
        buckets[bucket]
          ..add(x * cell + cell / 2)
          ..add(y * cell + cell / 2);
      }
    }
    final paint = Paint()
      ..strokeWidth = cell
      ..strokeCap = StrokeCap.square;
    for (var i = 0; i < 6; i++) {
      final level = ((i % 3) + 1) / 3;
      final base = i < 3 ? Colors.white : Colors.black;
      paint.color = base.withValues(alpha: (strength * level * 2).clamp(0.0, 1.0));
      canvas.drawRawPoints(ui.PointMode.points, Float32List.fromList(buckets[i]), paint);
    }
    return recorder.endRecording().toImageSync((cols * cell).ceil(), (rows * cell).ceil());
  }

  @override
  bool shouldRepaint(covariant _FallbackPainter old) => true;
}

/// Paleta 6 slotů: [základ, stín, jádro, střed, highlight, doplněk].
List<Color> _paletteFor(Color? accent, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  if (accent == null) {
    // Pestrá paleta jen dokud nic není vybrané -- magenta/azurová/oranžová/
    // fialová/zelená jako v referencích.
    return dark
        ? const [
            Color(0xFF0B0714),
            Color(0xFF7B2CFF),
            Color(0xFFE0359A),
            Color(0xFF12B5CB),
            Color(0xFFFF8A3D),
            Color(0xFF2BD67B),
          ]
        : const [
            Color(0xFFFFF4FA),
            Color(0xFFB794FF),
            Color(0xFFFF7EC3),
            Color(0xFF6FE3F0),
            Color(0xFFFFC08A),
            Color(0xFF8CF0B5),
          ];
  }
  final hsl = HSLColor.fromColor(accent);
  final h = hsl.hue;
  final s = hsl.saturation.clamp(0.45, 0.9);
  Color tone(double dh, double sf, double l) =>
      HSLColor.fromAHSL(1, (h + dh) % 360, (s * sf).clamp(0.0, 1.0), l).toColor();
  return dark
      ? [
          tone(8, 0.7, 0.05),
          tone(-12, 1.0, 0.20),
          tone(0, 1.0, 0.40),
          tone(14, 0.9, 0.54),
          tone(-6, 0.6, 0.74),
          tone(4, 1.0, 0.30),
        ]
      : [
          tone(0, 0.35, 0.95),
          tone(-12, 0.8, 0.82),
          tone(0, 1.0, 0.66),
          tone(14, 0.9, 0.56),
          tone(-6, 0.5, 0.92),
          tone(4, 1.0, 0.74),
        ];
}

/// OKLab barva -- míchání v něm nekalí přechody do šeda/hněda jako sRGB.
class _Lab {
  const _Lab(this.l, this.a, this.b);

  final double l;
  final double a;
  final double b;

  static double _toLinear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  static double _toSrgb(double c) =>
      c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

  factory _Lab.fromColor(Color color) {
    final r = _toLinear(color.r), g = _toLinear(color.g), bl = _toLinear(color.b);
    final l = math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl, 1 / 3).toDouble();
    final m = math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl, 1 / 3).toDouble();
    final s = math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl, 1 / 3).toDouble();
    return _Lab(
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    );
  }

  Color toColor() {
    final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    final lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_;
    double ch(double v) => _toSrgb(v.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    return Color.from(
      alpha: 1,
      red: ch(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
      green: ch(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
      blue: ch(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc),
    );
  }

  static _Lab lerp(_Lab x, _Lab y, double t) =>
      _Lab(x.l + (y.l - x.l) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t);
}
