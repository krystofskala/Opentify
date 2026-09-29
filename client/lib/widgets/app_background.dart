import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/reduced_motion.dart';
import '../theme/accent_color.dart' show CoverCharacter, isAchromatic;

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
    this.supportTones = const [],
    this.character,
    required this.brightness,
    required this.isPlaying,
    required this.hidden,
    required this.child,
  });

  final Color? selectedAccent;

  /// Doplňkové tóny z obalu (`effectiveSupportTonesProvider`) -- odstíny
  /// vedlejších slotů monochromatické palety; prázdné = syntetický posun.
  final List<Color> supportTones;

  /// Charakter obalu (průměrná sytost/světlost) -- pastelový obal = jemná
  /// světlá paleta, temný = hluboká, sytý = sytá. `null` = jen z barvy.
  final CoverCharacter? character;
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
  Curve _tweenCurve = Curves.easeInOutCubic;

  double _phase = 0;
  // Posun tekutého pole (jednotky šumu). Perioda 256 = perioda mřížky šumu,
  // takže přetečení je bezešvé.
  double _flow = 0;
  double _speed = 1;
  double _boost = 0;
  double _boostTarget = 0;
  double _bloom = 0;
  double _lastPaintAt = 0;
  double _lastScrollAt = 0;
  double _pixelRatio = 1;
  bool _reducedMotion = false;

  // Delší přechod -- zrno se přebarvuje zrnko po zrnku (shader), má to být
  // pozvolné, ne blik.
  static const _tweenSeconds = 2.8;
  static const _staggerSeconds = 0.06;

  double get _now => _clock.elapsedMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    final palette = _paletteFor(widget.selectedAccent, widget.brightness, widget.supportTones, widget.character)
        .map(_Lab.fromColor)
        .toList();
    _from = palette;
    _to = palette;
    _ticker = createTicker(_onTick);
    _program.then((program) {
      if (!mounted) return;
      if (!_loggedPath) {
        _loggedPath = true;
        debugPrint(
            program != null ? 'AppBackground: fragment shader aktivní' : 'AppBackground: canvas gradient + zrno');
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
    if (old.selectedAccent != widget.selectedAccent ||
        old.brightness != widget.brightness ||
        !listEquals(old.supportTones, widget.supportTones) ||
        old.character != widget.character) {
      // "Záblesk" jen u samostatné změny -- při rychlém přeskakování skladeb
      // by jinak pozadí pulzovalo s každým klepnutím.
      final retarget = _tweening(_now);
      _startTween(_paletteFor(widget.selectedAccent, widget.brightness, widget.supportTones, widget.character));
      if (!retarget && old.selectedAccent != null && widget.selectedAccent != null && !_reducedMotion) _bloom = 0.3;
    }
    if (old.hidden != widget.hidden || old.isPlaying != widget.isPlaying) _wake();
  }

  /// Přechod vždy začíná z AKTUÁLNĚ vykreslené (rozpracované) barvy každého
  /// slotu -- nová cílová barva uprostřed přechodu ho jen přesměruje, nikdy
  /// neskočí zpátky na starou výchozí barvu. Přesměrování navíc jede
  /// `easeOutCubic` (rozjeté hned od začátku), ne znovu od nulové rychlosti
  /// `easeInOutCubic` -- jinak by rychlé přepínání skladeb barvu "brzdilo"
  /// a přechod by působil trhaně.
  void _startTween(List<Color> palette) {
    final now = _now;
    final retarget = _tweening(now);
    _from = List.generate(6, (i) => _slotAt(i, now));
    _to = palette.map(_Lab.fromColor).toList();
    _tweenStart = now;
    _tweenCurve = retarget ? Curves.easeOutCubic : Curves.easeInOutCubic;
    _wake();
  }

  double get _tweenDuration => _reducedMotion ? 0.4 : _tweenSeconds;
  double get _stagger => _reducedMotion ? 0 : _staggerSeconds;
  bool _tweening(double now) => now < _tweenStart + _tweenDuration + _stagger * 5;

  /// Průběh přechodu pro shader (jedna hodnota, bez posunu mezi sloty --
  /// rozfázování obstará práh každého zrnka).
  double _mixAt(double now) => _tweenCurve.transform(((now - _tweenStart) / _tweenDuration).clamp(0.0, 1.0));

  _Lab _slotAt(int i, double now) {
    final raw = ((now - _tweenStart - i * _stagger) / _tweenDuration).clamp(0.0, 1.0);
    final t = _tweenCurve.transform(raw);
    return _Lab.lerp(_from[i], _to[i], t);
  }

  void _wake() {
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
      // Klid ~40 s na smyčku (pozadí se hýbe pořád -- uživatel si to
      // přál místo statického klidu), při přehrávání ~20 s (náběh ~1.5 s).
      final targetSpeed = widget.isPlaying ? 3.0 : 1.5;
      _speed += (targetSpeed - _speed) * (1 - math.exp(-step / 0.5));
      final tau = _boostTarget > _boost ? 0.12 : 0.8;
      _boost += (_boostTarget - _boost) * (1 - math.exp(-step / tau));
      if (now - _lastScrollAt > 0.12) _boostTarget *= math.exp(-step / 0.15);
      _bloom *= math.exp(-step / 0.2);
      _phase = (_phase + step * _speed * (1 + 3 * _boost)) % 600;
      _flow = (_flow + step * _speed * (1 + 3 * _boost) * 0.02) % 256;
    }
    _frame.value++;

    // Animuje se nepřetržitě (30 fps strop výš); zastaví se jen při
    // systémovém "omezit pohyb" nebo když je pozadí skryté.
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
      child: _BackgroundScope(
        state: this,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Každá vrstva přímé dítě `Stack`u -- `Positioned` uvnitř
            // `RepaintBoundary` dřív shazoval release build.
            RepaintBoundary(child: IgnorePointer(child: CustomPaint(painter: painter))),
            widget.child,
          ],
        ),
      ),
    );
  }
}

class _BackgroundScope extends InheritedWidget {
  const _BackgroundScope({required this.state, required super.child});

  final _AppBackgroundState state;

  @override
  bool updateShouldNotify(_BackgroundScope oldWidget) => state != oldWidget.state;
}

/// Kopie živého pozadí appky (stejná paleta, fáze i zrno ve stejném
/// snímku) -- pro skleněný panel přehrávače, který obsah stránky pod sebou
/// úplně zakryje, ale gradient v barvě skladby má prosvítat. Musí mít
/// velikost celé obrazovky a ležet na jejím počátku (volající ji posune
/// o polohu panelu), jinak by nenavazovala na pozadí kolem.
class AppBackgroundMirror extends StatelessWidget {
  const AppBackgroundMirror({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.dependOnInheritedWidgetOfExactType<_BackgroundScope>()?.state;
    if (state == null) return const SizedBox.expand();
    final painter = state._programReady != null
        ? _ShaderPainter(state: state, repaint: state._frame)
        : _FallbackPainter(state: state, repaint: state._frame);
    return RepaintBoundary(child: IgnorePointer(child: CustomPaint(painter: painter, size: Size.infinite)));
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter({required this.state, required Listenable repaint}) : super(repaint: repaint);

  final _AppBackgroundState state;

  // Gradient se počítá v LOGICKÉM rozlišení (na iPhonu 3× hustota = 9×
  // méně pixelů) do obrázku jednou za snímek -- je měkký, zmenšení není
  // vidět. Pozadí i `AppBackgroundMirror` (panel přehrávače) pak stejný
  // obrázek jen vykreslí; dřív se celý shader počítal dvakrát za snímek na
  // plném rozlišení a appka při nahrávání obrazovky trhala (živě nahlášeno).
  // Ostré zrno jde přes to jako hotová vrstva ve fyzickém rozlišení.
  static ui.Image? _image;
  static int _imageFrame = -1;
  static Size? _imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final program = state._programReady;
    if (program == null || size.isEmpty) return;
    final frame = state._frame.value;
    if (_image == null || _imageFrame != frame || _imageSize != size) {
      final next = _render(program, size);
      _image?.dispose();
      _image = next;
      _imageFrame = frame;
      _imageSize = size;
    }
    final image = _image!;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    final dark = state.widget.brightness == Brightness.dark;
    final grain = _FallbackPainter.grainFor(size, state._pixelRatio, dark);
    canvas.drawImageRect(
      grain,
      Rect.fromLTWH(0, 0, grain.width.toDouble(), grain.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  ui.Image _render(ui.FragmentProgram program, Size size) {
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
      ..setFloat(4, 0) // zrno kreslí hotová vrstva ve fyzickém rozlišení
      ..setFloat(5, state._pixelRatio)
      ..setFloat(6, state._bloom)
      ..setFloat(7, isDark ? 1 : 0);
    // Nová (cílová) a předchozí paleta + průběh -- shader přebarvuje zrnko
    // po zrnku (viz shaders/chroma_grain.frag, uMix).
    for (var i = 0; i < 6; i++) {
      final c = state._to[i].toColor();
      final p = state._from[i].toColor();
      shader
        ..setFloat(8 + i * 3, c.r)
        ..setFloat(9 + i * 3, c.g)
        ..setFloat(10 + i * 3, c.b)
        ..setFloat(26 + i * 3, p.r)
        ..setFloat(27 + i * 3, p.g)
        ..setFloat(28 + i * 3, p.b);
    }
    shader.setFloat(44, state._mixAt(now));
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & size, Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size.width.ceil(), size.height.ceil());
    picture.dispose();
    return image;
  }

  @override
  bool shouldRepaint(covariant _ShaderPainter old) => true;
}

/// Výchozí vykreslování: tekuté pole barev, které se "míchají" jako
/// rozmíchaný inkoust -- ne oddělené záře na tmavé podlaze (uživatel: "jako
/// světlo z reflektorů na podlaze"). Na CPU se v hrubé síti (~24-64 × 24-96
/// vrcholů) spočítá dvakrát doménově pokřivený hodnotový šum (tekoucí v čase)
/// a z něj směs 6 barev palety v OKLab (míchání nekalí do šeda). GPU pak
/// barvy mezi vrcholy plynule interpoluje (`drawVertices`), přes to jde
/// předpočítané filmové zrno. Fragment shader je jen volitelný
/// (`BG_SHADER=true`): v CanvasKitu při plynulém překreslování rozbíjel
/// vykreslování obrázků (obaly alb černaly).
class _FallbackPainter extends CustomPainter {
  _FallbackPainter({required this.state, required Listenable repaint}) : super(repaint: repaint);

  final _AppBackgroundState state;
  static ui.Image? _grain;
  static String? _grainKey;
  static final _FlowMesh _mesh = _FlowMesh();
  static ui.Vertices? _cachedVertices;
  static int _cachedFrame = -1;
  static Size? _cachedSize;

  // Síť vzniká 30× za sekundu. Neuvolněné `Vertices` žijí ve WASM paměti
  // CanvasKitu, dokud je nesebere GC -- Safari to dělá velmi líně, paměť za
  // desítky minut přehrávání nabobtnala a iOS pak appku při navigaci
  // (načítání obalů) zmrazil (živě nahlášeno: "zamrzne, musím restartovat").
  // Uvolňují se ručně, se zpožděním pár snímků, ať je nepoužívá rozpracovaný
  // snímek.
  static final List<ui.Vertices> _retired = [];
  static ui.Gradient? _vignette;
  static Size? _vignetteSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final now = state._now;
    final dark = state.widget.brightness == Brightness.dark;
    final palette = List.generate(6, (i) => state._slotAt(i, now));

    // Stejný snímek kreslí i `AppBackgroundMirror` (panel přehrávače) --
    // síť se počítá jen jednou za snímek.
    final frame = state._frame.value;
    if (_cachedFrame != frame || _cachedSize != size || _cachedVertices == null) {
      if (_cachedVertices case final old?) _retired.add(old);
      while (_retired.length > 3) {
        _retired.removeAt(0).dispose();
      }
      _cachedVertices = _mesh.build(
        size,
        palette,
        flow: state._flow,
        warp: 3.2 * (1 + 0.3 * state._boost) + 0.6 * state._bloom,
        lift: 0.05 * state._bloom,
        dark: dark,
      );
      _cachedFrame = frame;
      _cachedSize = size;
    }
    final vertices = _cachedVertices!;
    canvas.drawVertices(vertices, BlendMode.dst, Paint());

    if (dark) {
      // Jen jemné ztmavení okrajů kvůli hloubce -- dřívější silná vinětka
      // dělala z okrajů tu "tmavou podlahu".
      // Jeden gradient na velikost okna, ne nový každý snímek (viz `_retired`).
      if (_vignette == null || _vignetteSize != size) {
        _vignetteSize = size;
        _vignette = ui.Gradient.radial(
          size.center(Offset.zero),
          size.longestSide * 0.8,
          [Colors.transparent, Colors.black.withValues(alpha: 0.14)],
          const [0.55, 1],
        );
      }
      canvas.drawRect(Offset.zero & size, Paint()..shader = _vignette);
    }

    final grain = grainFor(size, state._pixelRatio, dark);
    canvas.drawImageRect(
      grain,
      Rect.fromLTWH(0, 0, grain.width.toDouble(), grain.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  /// Předpočítaná vrstva zrna (sdílí ji i shaderová cesta).
  static ui.Image grainFor(Size size, double dpr, bool dark) {
    final key = '${size.width.round()}x${size.height.round()}@$dpr/$dark';
    if (_grain == null || _grainKey != key) {
      _grain?.dispose();
      _grainKey = key;
      _grain = _buildGrain(size, dpr, dark);
    }
    return _grain!;
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

/// Hrubá síť vrcholů s barvami z tekutého pole. Pozice a indexy se drží,
/// dokud se nezmění velikost; barvy se počítají každý snímek (jen pár tisíc
/// vrcholů, levné i v JS). Staré `Vertices` se uvolňují se zpožděním pár
/// snímků -- ať je CanvasKit ještě nepoužívá v rozpracovaném snímku.
class _FlowMesh {
  Size? _size;
  int _cols = 0;
  int _rows = 0;
  Float32List _positions = Float32List(0);
  Uint16List _indices = Uint16List(0);
  Int32List _colors = Int32List(0);

  static final Uint8List _perm = () {
    final random = math.Random(11);
    final base = List<int>.generate(256, (i) => i)..shuffle(random);
    final out = Uint8List(512);
    for (var i = 0; i < 512; i++) {
      out[i] = base[i & 255];
    }
    return out;
  }();
  static final Float64List _values = () {
    final random = math.Random(23);
    return Float64List.fromList(List.generate(256, (_) => random.nextDouble()));
  }();

  void _layout(Size size) {
    _size = size;
    _cols = (size.width / 16).round().clamp(24, 64);
    _rows = (size.height / 16).round().clamp(24, 96);
    final vx = _cols + 1;
    final count = vx * (_rows + 1);
    _positions = Float32List(count * 2);
    _colors = Int32List(count);
    for (var j = 0; j <= _rows; j++) {
      for (var i = 0; i <= _cols; i++) {
        final k = (j * vx + i) * 2;
        _positions[k] = size.width * i / _cols;
        _positions[k + 1] = size.height * j / _rows;
      }
    }
    _indices = Uint16List(_cols * _rows * 6);
    var n = 0;
    for (var j = 0; j < _rows; j++) {
      for (var i = 0; i < _cols; i++) {
        final a = j * vx + i;
        final b = a + 1;
        final c = a + vx;
        final d = c + 1;
        _indices
          ..[n++] = a
          ..[n++] = b
          ..[n++] = c
          ..[n++] = b
          ..[n++] = d
          ..[n++] = c;
      }
    }
  }

  static double _noise(double x, double y) {
    final xf = x.floorToDouble();
    final yf = y.floorToDouble();
    final xi = xf.toInt() & 255;
    final yi = yf.toInt() & 255;
    final tx = x - xf;
    final ty = y - yf;
    final u = tx * tx * (3 - 2 * tx);
    final v = ty * ty * (3 - 2 * ty);
    final a = _values[_perm[_perm[xi] + yi]];
    final b = _values[_perm[_perm[xi + 1] + yi]];
    final c = _values[_perm[_perm[xi] + yi + 1]];
    final d = _values[_perm[_perm[xi + 1] + yi + 1]];
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
  }

  static double _fbm(double x, double y) => (_noise(x, y) + 0.5 * _noise(2 * x + 17.3, 2 * y + 5.1)) / 1.5;

  static double _smooth(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  ui.Vertices build(
    Size size,
    List<_Lab> p, {
    required double flow,
    required double warp,
    required double lift,
    required bool dark,
  }) {
    // Tmavý režim: celé pole tmavší (bílý text musí být čitelný) a víc
    // prostoru pro nejhlubší tón -- pořád ale barva, žádná černá podlaha.
    final lightness = dark ? 0.66 : 1.0;
    final deepWeight = dark ? 0.95 : 0.6;
    if (_size != size) _layout(size);
    final short = size.shortestSide;
    // Na telefonu hustší pole: se stejným měřítkem jako desktop zabrala
    // jedna barevná skvrna skoro celou šířku a prolínání bylo málo vidět
    // (živě nahlášeno). Desktop (kratší strana ≥ 600) beze změny.
    final density = 1.5 * (600 / short).clamp(1.0, 1.45);
    final ax = size.width / short * density;
    final ay = size.height / short * density;
    final vx = _cols + 1;

    for (var j = 0; j <= _rows; j++) {
      final py = j / _rows * ay;
      for (var i = 0; i <= _cols; i++) {
        final px = i / _cols * ax;
        // Dvojitě pokřivená doména (Quilez) -> mramorované, stáčející se
        // proudy. Čas jen s celočíselnými koeficienty => bezešvá perioda 256.
        final qx = _fbm(px + flow, py + flow);
        final qy = _fbm(px + 5.2 - flow, py + 1.3 + flow);
        final rx = _fbm(px + warp * qx + 1.7, py + warp * qy + 9.2 - flow);
        final ry = _fbm(px + warp * qx + 8.3 + flow, py + warp * qy + 2.8);
        final f = _fbm(px + warp * rx, py + warp * ry);

        // Barvy se do sebe vmíchávají (vážené přechody přes celou plochu),
        // nikde "díra" do černa: i nejtmavší slot palety je barevný.
        var c = _Lab.lerp(p[1], p[2], _smooth(f * 2.2 - 0.6));
        c = _Lab.lerp(c, p[3], _smooth(qx * 2.4 - 1.0));
        c = _Lab.lerp(c, p[5], _smooth(ry * 2.6 - 1.4));
        c = _Lab.lerp(c, p[0], _smooth(1.05 - (rx + qy) * 1.1) * deepWeight);
        c = _Lab.lerp(c, p[4], _smooth(f * rx * 4.2 - 1.9) * 0.85);
        _colors[j * vx + i] = c.toArgb(lift, lightness);
      }
    }

    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      _positions,
      colors: _colors,
      indices: _indices,
    );
  }
}

/// Paleta 6 slotů: [základ, stín, jádro, střed, highlight, doplněk].
List<Color> _paletteFor(
  Color? accent,
  Brightness brightness, [
  List<Color> supportTones = const [],
  CoverCharacter? character,
]) {
  final dark = brightness == Brightness.dark;
  if (accent == null) return dark ? _startDark : _startLight;
  if (isAchromatic(accent)) {
    // Černobílý/šedý obal: šedá má v HSL odstín 0° (= červená), takže
    // zvednutí sytosti níž by z ní udělalo červenou appku. Neutrální
    // monochrom bez odstínu -- grafit/stříbro v tmavém, teplá šeď/papír ve
    // světlém režimu (L ≥ 0.72 kvůli kontrastu textu, viz níž).
    // Širší rozsah jasu (téměř černá -> jasná stříbrná záře) a jemná teplota
    // (chladný grafit vs. teplé stříbro, sytost ≤ 0.08) -- s úzkým rozsahem
    // čistých šedých nebyl pohyb gradientu skoro vidět (živě nahlášeno).
    Color grey(double l, {double hue = 0, double s = 0}) => HSLColor.fromAHSL(1, hue, s, l).toColor();
    return dark
        ? [
            grey(0.06, hue: 220, s: 0.08),
            grey(0.20, hue: 215, s: 0.07),
            grey(0.36, hue: 35, s: 0.05),
            grey(0.50, hue: 210, s: 0.05),
            grey(0.78, hue: 40, s: 0.06),
            grey(0.28, hue: 30, s: 0.06),
          ]
        : [
            grey(0.97, hue: 40, s: 0.08),
            grey(0.82, hue: 215, s: 0.05),
            grey(0.74, hue: 40, s: 0.06),
            grey(0.72, hue: 210, s: 0.05),
            grey(0.99, hue: 45, s: 0.08),
            grey(0.78, hue: 35, s: 0.06),
          ];
  }
  final hsl = HSLColor.fromColor(accent);
  final h = hsl.hue;
  // Charakter obalu, ne jen odstín: sytost palety ŠKÁLUJE průměrnou sytost
  // obalu (pastelový/prachový obal -> jemná paleta, sytý -> sytá; dřív se
  // všechno zvedlo na ≥ 0.45 a krémový obal vypadal stejně jako sytě
  // červený). Malá podlaha jen proto, že šedé obaly řeší větev výš.
  final coverSat = (character?.saturation ?? hsl.saturation).clamp(0.0, 1.0);
  final coverLight = (character?.lightness ?? 0.5).clamp(0.0, 1.0);
  final s = math.max(0.26, ui.lerpDouble(0.26, 0.85, coverSat)!);
  // Světlost sleduje světlost obalu: světlý pastel posune paletu výš a
  // stáhne kontrast mezi sloty (měkčí), temný obal ji posune do hloubky.
  // Tmavý režim zůstává tmavý a světlý světlý (L ≥ 0.72 kvůli textu).
  final brightness01 = coverLight - 0.5;
  final spread = 1 - math.max(0.0, brightness01) * 0.5;
  double lit(double base) => dark
      ? (0.40 + (base - 0.40) * spread + brightness01 * 0.3).clamp(0.05, 0.8)
      : (0.84 + (base - 0.84) * spread + brightness01 * 0.12).clamp(0.72, 0.97);
  Color tone(double dh, double sf, double l) => _keepOkHue(
        HSLColor.fromAHSL(1, (h + dh) % 360, (s * sf).clamp(0.0, 1.0), lit(l)).toColor(),
        HSLColor.fromAHSL(1, (h + dh) % 360, hsl.saturation, hsl.lightness).toColor(),
      );

  // Známe skutečné převládající barvy obalu -> paleta z nich: odstín a
  // sytost každého slotu z reálné barvy obalu (převládající barva na
  // největší plochy, nejtmavší na hloubku, nejsvětlejší na světla),
  // světlost ze struktury výš (čitelnost). Krémový obal s vínovou kresbou
  // tak dá krémovo-pískové pozadí s vínovými akcenty, ne červené pole.
  final tones = character?.tones ?? const <Color>[];
  double toneChroma(Color c) {
    final t = HSLColor.fromColor(c);
    return (1 - (2 * t.lightness - 1).abs()) * t.saturation;
  }

  // Paleta z tónů obalu jen když aspoň dva z nich mají barvu -- u vybledlého
  // obalu by z šedých tónů vyšlo zase šedé pozadí; tam radši tlumený
  // monochrom v odstínu akcentu (větev níž).
  if (tones.where((c) => toneChroma(c) >= 0.04).length >= 2) {
    final byLight = [...tones]
      ..sort((a, b) => HSLColor.fromColor(a).lightness.compareTo(HSLColor.fromColor(b).lightness));
    final darkest = byLight.first;
    final lightest = byLight.last;
    final t0 = tones[0];
    final t1 = tones[1];
    final t2 = tones.length > 2 ? tones[2] : t1;
    Color from(Color c, double l) {
      final src = HSLColor.fromColor(c);
      final target = lit(l);
      // Zachovat CHROMU (skutečnou barevnost), ne HSL sytost: bledý krém má
      // HSL sytost klidně 0.6, ale chromu ~0.1 -- přenesená sytost by z něj
      // v tmavé světlosti udělala syté okrové pole.
      final chroma = (1 - (2 * src.lightness - 1).abs()) * src.saturation;
      final room = math.max(0.05, 1 - (2 * target - 1).abs());
      // Papír/šeď zůstane skoro neutrální (ne červená z odstínu 0°).
      // Tlumené barvy zesílit (×1.6) -- 1:1 přenesená chroma dělala z
      // prachových obalů skoro šedé pozadí (živě nahlášeno).
      final sat = chroma < 0.03 ? 0.03 : math.min(0.85, chroma * 1.6 / room);
      return _keepOkHue(HSLColor.fromAHSL(1, src.hue, sat, target).toColor(), c);
    }

    // Kontrastní akcent obalu (žlutá kresba na modré) = jedno světlo místo
    // "nejsvětlejšího" tónu; u tmavého režimu tlumené, ať nekřičí.
    final accentTone = character?.accent;
    final glowDark = accentTone != null ? from(accentTone, 0.55) : from(lightest, 0.72);
    final glowLight = accentTone != null ? from(accentTone, 0.88) : from(t1, 0.93);
    return dark
        ? [from(darkest, 0.13), from(t0, 0.24), from(t0, 0.42), from(t1, 0.55), glowDark, from(t2, 0.32)]
        : [from(lightest, 0.95), from(t0, 0.86), from(t0, 0.76), from(t1, 0.72), glowLight, from(t2, 0.8)];
  }
  // Doplňkové tóny obalu dávají vedlejším slotům (stín, střed) skutečné
  // odstíny z obalu místo syntetického posunu -- sytost a světlost slotů
  // zůstávají ze struktury výš, mění se jen odstínové nuance.
  double offsetTo(Color c) => ((HSLColor.fromColor(c).hue - h + 540) % 360) - 180;
  final dA = supportTones.isNotEmpty ? offsetTo(supportTones[0]) : null;
  final dB = supportTones.length > 1 ? offsetTo(supportTones[1]) : null;
  return dark
      ? [
          tone(10, 0.9, 0.13),
          tone(dA ?? -14, 1.0, 0.24),
          tone(0, 1.0, 0.42),
          tone(dB ?? 16, 0.9, 0.55),
          tone(-6, 0.7, 0.72),
          tone(dA != null ? dA / 2 : 6, 1.0, 0.32),
        ]
      // Světlý režim: nejtmavší tón L≥0.72 -- tmavý text (`onSurface`) musí
      // mít na kterémkoliv místě pole kontrast ≥ 4.5:1 (HIG Accessibility).
      // Dřív L 0.56/0.66 → nadpisy a odkazy tmavé na tmavém.
      : [
          tone(0, 0.35, 0.95),
          tone(dA ?? -12, 0.8, 0.86),
          tone(0, 1.0, 0.76),
          tone(dB ?? 14, 0.9, 0.72),
          tone(-6, 0.5, 0.93),
          tone(dA != null ? dA / 2 : 4, 1.0, 0.8),
        ];
}

/// Pestrá úvodní paleta (dokud nic není vybrané) -- stejné odstíny, jak je
/// má uživatel rád, ale ztlumené: sytost −20 % a světlosti slotů o ~22 %
/// blíž k sobě, ať "nebije do očí" víc než monochromatické stavy.
final List<Color> _startDark = _soften(_startDarkRaw);
final List<Color> _startLight = _soften(_startLightRaw);

List<Color> _soften(List<Color> raw) {
  final hsl = raw.map(HSLColor.fromColor).toList();
  final meanL = hsl.fold<double>(0, (a, c) => a + c.lightness) / hsl.length;
  return [
    for (final c in hsl)
      c
          .withSaturation((c.saturation * 0.8).clamp(0.0, 1.0))
          .withLightness((meanL + (c.lightness - meanL) * 0.78).clamp(0.0, 1.0))
          .toColor(),
  ];
}

// Magenta/azurová/oranžová/fialová/zelená jako v referencích.
const List<Color> _startDarkRaw = [
  // Nejtmavší tón je sytá indigová, ne skoro černá -- žádná "podlaha".
  Color(0xFF2A1060),
  Color(0xFF7B2CFF),
  Color(0xFFE0359A),
  Color(0xFF12B5CB),
  Color(0xFFFF8A3D),
  Color(0xFF2BD67B),
];
const List<Color> _startLightRaw = [
  Color(0xFFFFF4FA),
  Color(0xFFB794FF),
  Color(0xFFFF7EC3),
  Color(0xFF6FE3F0),
  Color(0xFFFFC08A),
  Color(0xFF8CF0B5),
];

/// Vrátí `color` se stejnou světlostí a chromou (OKLCH), ale s OKLCH
/// odstínem `reference`. HSL zesvětlení posouvá vnímaný odstín -- tmavě
/// modrý obal (242°) dával v HSL světlejší tóny do fialova (živě
/// nahlášeno); OKLCH drží odstín tak, jak ho vidí oko. Mimo gamut se
/// chroma stáhne, odstín zůstane.
Color _keepOkHue(Color color, Color reference) {
  final ref = _Lab.fromColor(reference);
  final refChroma = math.sqrt(ref.a * ref.a + ref.b * ref.b);
  if (refChroma < 0.02) return color; // šeď nemá odstín, který by šlo držet
  final lab = _Lab.fromColor(color);
  final hue = math.atan2(ref.b, ref.a);
  var chroma = math.sqrt(lab.a * lab.a + lab.b * lab.b);
  for (var i = 0; i < 24; i++) {
    final candidate = _Lab(lab.l, chroma * math.cos(hue), chroma * math.sin(hue));
    if (candidate.inGamut) return candidate.toColor();
    chroma *= 0.9;
  }
  return _Lab(lab.l, 0, 0).toColor();
}

/// OKLab barva -- míchání v něm nekalí přechody do šeda/hněda jako sRGB.
class _Lab {
  const _Lab(this.l, this.a, this.b);

  final double l;
  final double a;
  final double b;

  static double _toLinear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  static double _toSrgb(double c) => c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

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

  /// Jako `toColor`, jen rovnou ARGB int bez alokace (tisíce vrcholů/snímek).
  /// `lift` přičte k světlosti (krátký "bloom" při změně barvy).
  int toArgb([double lift = 0, double scale = 1]) {
    final ll = l * scale + lift;
    final l_ = ll + 0.3963377774 * a + 0.2158037573 * b;
    final m_ = ll - 0.1055613458 * a - 0.0638541728 * b;
    final s_ = ll - 0.0894841775 * a - 1.2914855480 * b;
    final lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_;
    int ch(double v) => (_toSrgb(v.clamp(0.0, 1.0)).clamp(0.0, 1.0) * 255).round();
    final r = ch(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc);
    final g = ch(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc);
    final bl = ch(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc);
    return (0xFF << 24 | r << 16 | g << 8 | bl).toSigned(32);
  }

  bool get inGamut {
    final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    final lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_;
    bool ok(double v) => v >= -0.001 && v <= 1.001;
    return ok(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc) &&
        ok(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc) &&
        ok(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc);
  }

  static _Lab lerp(_Lab x, _Lab y, double t) =>
      _Lab(x.l + (y.l - x.l) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t);
}
