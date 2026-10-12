import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/design_tokens.dart' show AppFontSize;

/// Vlnovkový posuvník přehrávání podle Material 3 Expressive
/// `LinearWavyProgressIndicator` (AndroidX Compose Material 3, Apache 2.0,
/// viz NOTICE): vlna z kvadratických Bézierových oblouků po půlvlnách, fáze
/// posouvaná o jednu vlnovou délku za sekundu, náběh amplitudy 500 ms
/// (standardní křivka) a doběh 500 ms (zdůrazněné zrychlení), mezera mezi
/// průběhem a stopou. Vlastní doplňky: vlna u puku plynule doběhne do roviny
/// a puk se při tažení protáhne z kolečka do svislé čárky.
///
/// - Vlní se jen odehraná část, zbytek je vždy rovná čára.
/// - Amplituda doběhne na nulu, když nic nehraje nebo se táhne.
/// - `interactive: false` (mini přehrávač) vypne všechna gesta -- jen
///   vizuál, klepnutí patří rodiči (rozbalení přehrávače).
/// - Kreslí `CustomPainter` napojený na animace (`repaint`), takže animace
///   nepřestavují strom widgetů.
class WavySeekBar extends StatefulWidget {
  const WavySeekBar({
    super.key,
    required this.progress,
    this.onChanged,
    this.onChangeEnd,
    this.isPlaying = false,
    this.interactive = true,
    this.tapToSeek = true,
    this.activeColor = Colors.white,
    this.inactiveColor = const Color(0x4DFFFFFF),
    this.thumbColor = Colors.white,
    this.height = 28,
    this.strokeWidth = 3.5,
    this.thumbRadius = 6,
    this.wavelength = 22,
    this.waveAmplitude = 3.5,
    this.dragLabel,
  });

  /// 0..1, poloha přehrávání.
  final double progress;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final bool isPlaying;
  final bool interactive;

  /// `false` (mini přehrávač): posun jen tažením do strany -- klepnutí patří
  /// rodiči (rozbalení přehrávače), svislé tažení taky (zavření).
  final bool tapToSeek;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double height;
  final double strokeWidth;
  final double thumbRadius;
  final double wavelength;
  final double waveAmplitude;

  /// Při tažení bublina s textem nad prstem (čas, kam se přetočí) -- mini
  /// přehrávač u dlouhých věcí (Adam, 8. 10.: "aspoň při ručním posuvu").
  final String Function(double value)? dragLabel;

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar> with TickerProviderStateMixin {
  // Tokeny M3 Expressive (MotionTokens): DurationLong2 = 500 ms,
  // EasingStandard (0.2, 0, 0, 1), EasingEmphasizedAccelerate (0.3, 0, 0.8, 0.15).
  static const _amplitudeDuration = Duration(milliseconds: 500);
  static const _standard = Cubic(0.2, 0, 0, 1);
  static const _emphasizedAccelerate = Cubic(0.3, 0, 0.8, 0.15);
  static const _thumbMorph = Duration(milliseconds: 200);

  late final AnimationController _amplitude = AnimationController(vsync: this, duration: _amplitudeDuration);
  late final CurvedAnimation _amplitudeCurve = CurvedAnimation(
    parent: _amplitude,
    curve: _standard,
    reverseCurve: _emphasizedAccelerate.flipped,
  );
  late final AnimationController _dragging = AnimationController(vsync: this, duration: _thumbMorph);

  /// Fáze vlny 0..1 (jedna vlnová délka); posouvá ji ticker, jen když se
  /// vlní -- v klidu žádné snímky.
  final ValueNotifier<double> _phase = ValueNotifier(0);
  late final _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;

  /// Poloha prstu během tažení (a chvíli po něm, než přehrávač ohlásí novou
  /// pozici -- jinak by puk na okamžik skočil zpátky).
  double? _dragValue;
  double? _pendingValue;
  DateTime _pendingSince = DateTime.now();

  final _labelLink = LayerLink();
  final _labelPortal = OverlayPortalController();

  bool get _isDragging => _dragValue != null;

  double get _shownValue => (_dragValue ?? _pendingValue ?? widget.progress).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _amplitude.value = _wantsWave ? 1 : 0;
    _amplitude.addStatusListener((_) => _syncTicker());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker(); // i po změně „omezit pohyb“ v systému
  }

  @override
  void didUpdateWidget(WavySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pendingValue;
    if (pending != null &&
        ((widget.progress - pending).abs() < 0.02 ||
            DateTime.now().difference(_pendingSince) > const Duration(milliseconds: 1500))) {
      _pendingValue = null;
    }
    _updateAmplitudeTarget();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _amplitudeCurve.dispose();
    _amplitude.dispose();
    _dragging.dispose();
    _phase.dispose();
    super.dispose();
  }

  bool get _wantsWave => widget.isPlaying && !_isDragging && widget.waveAmplitude > 0;

  void _updateAmplitudeTarget() {
    if (_wantsWave) {
      if (_amplitude.status != AnimationStatus.forward && _amplitude.value < 1) _amplitude.forward();
    } else {
      if (_amplitude.status != AnimationStatus.reverse && _amplitude.value > 0) _amplitude.reverse();
    }
    _syncTicker();
  }

  /// Ticker běží, jen když je co vlnit (hraje, nebo amplituda ještě dobíhá)
  /// a pohyb není v systému vypnutý.
  void _syncTicker() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final needed = !reduceMotion && (widget.isPlaying || _amplitude.value > 0) && widget.wavelength > 0;
    if (needed && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!needed && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    // Rychlost = jedna vlnová délka za sekundu (výchozí `waveSpeed` M3).
    if (widget.isPlaying && !_isDragging) _phase.value = (_phase.value + dt) % 1.0;
    if (!widget.isPlaying && _amplitude.value == 0) _syncTicker();
  }

  // --- Gesta ---------------------------------------------------------------

  double _valueAt(Offset local, double width) {
    final inset = _inset;
    final usable = width - inset * 2;
    if (usable <= 0) return 0;
    return ((local.dx - inset) / usable).clamp(0.0, 1.0);
  }

  /// Čára vede skoro k okrajům (zarovnání s časy pod ní); puk smí na
  /// krajích lehce přesahovat -- `CustomPaint` neořezává.
  double get _inset => widget.strokeWidth / 2;

  void _startDrag(Offset local, double width) {
    setState(() {
      _dragValue = _valueAt(local, width);
      _pendingValue = null;
    });
    _dragging.forward();
    _updateAmplitudeTarget();
    if (widget.dragLabel != null) _labelPortal.show();
    widget.onChanged?.call(_dragValue!);
  }

  void _updateDrag(Offset local, double width) {
    setState(() => _dragValue = _valueAt(local, width));
    widget.onChanged?.call(_dragValue!);
  }

  void _endDrag() {
    final value = _dragValue;
    if (value == null) return;
    setState(() {
      _dragValue = null;
      _pendingValue = value;
      _pendingSince = DateTime.now();
    });
    _dragging.reverse();
    if (_labelPortal.isShowing) _labelPortal.hide();
    _updateAmplitudeTarget();
    widget.onChangeEnd?.call(value);
  }

  void _tap(Offset local, double width) {
    final value = _valueAt(local, width);
    setState(() {
      _pendingValue = value;
      _pendingSince = DateTime.now();
    });
    widget.onChanged?.call(value);
    widget.onChangeEnd?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
      Widget bar = CustomPaint(
        size: Size(width, widget.height),
        painter: _WavyPainter(
          value: _shownValue,
          phase: _phase,
          amplitude: _amplitudeCurve,
          dragging: _dragging,
          activeColor: widget.activeColor,
          inactiveColor: widget.inactiveColor,
          thumbColor: widget.thumbColor,
          strokeWidth: widget.strokeWidth,
          thumbRadius: widget.thumbRadius,
          wavelength: widget.wavelength,
          waveAmplitude: widget.waveAmplitude,
          inset: _inset,
        ),
      );
      bar = Semantics(
        slider: true,
        value: '${(_shownValue * 100).round()} %',
        child: SizedBox(width: width, height: widget.height, child: bar),
      );
      if (!widget.interactive || (widget.onChanged == null && widget.onChangeEnd == null)) {
        return ExcludeSemantics(excluding: !widget.interactive, child: bar);
      }
      bar = RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
            (r) => r
              ..onStart = ((d) => _startDrag(d.localPosition, width))
              ..onUpdate = ((d) => _updateDrag(d.localPosition, width))
              ..onEnd = ((_) => _endDrag())
              ..onCancel = _endDrag,
          ),
          if (widget.tapToSeek)
            TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (r) => r..onTapUp = ((d) => _tap(d.localPosition, width)),
            ),
        },
        child: bar,
      );
      final label = widget.dragLabel;
      if (label == null) return bar;
      return CompositedTransformTarget(
        link: _labelLink,
        child: OverlayPortal(
          controller: _labelPortal,
          overlayChildBuilder: (context) {
            final value = _dragValue ?? _shownValue;
            final x = _inset + (width - _inset * 2) * value;
            return Positioned(
              left: 0,
              top: 0,
              child: CompositedTransformFollower(
                link: _labelLink,
                showWhenUnlinked: false,
                offset: Offset(x, -6),
                followerAnchor: Alignment.bottomCenter,
                child: _DragBubble(text: label(value), color: widget.activeColor),
              ),
            );
          },
          child: bar,
        ),
      );
    });
  }
}

class _DragBubble extends StatelessWidget {
  const _DragBubble({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final onColor = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            text,
            style: TextStyle(
              color: onColor,
              fontSize: AppFontSize.small,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.value,
    required this.phase,
    required this.amplitude,
    required this.dragging,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.strokeWidth,
    required this.thumbRadius,
    required this.wavelength,
    required this.waveAmplitude,
    required this.inset,
  }) : super(repaint: Listenable.merge([phase, amplitude, dragging]));

  final double value;
  final ValueNotifier<double> phase;
  final Animation<double> amplitude;
  final Animation<double> dragging;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double strokeWidth;
  final double thumbRadius;
  final double wavelength;
  final double waveAmplitude;
  final double inset;

  /// Mezera mezi koncem průběhu (puk) a stopou -- M3 `TrackActiveSpace` 4 dp.
  static const _trackGap = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final start = inset;
    final end = size.width - inset;
    if (end <= start) return;
    final head = start + (end - start) * value;
    final drag = Curves.easeOutCubic.transform(dragging.value);

    // Puk: kolečko -> svislá čárka (šířka tahu, výška ~2,6× poloměr).
    final thumbW = _lerp(thumbRadius * 2, math.max(strokeWidth, 3.0), drag);
    final thumbH = math.min(size.height, _lerp(thumbRadius * 2, thumbRadius * 5.2, drag));

    // Stopa: rovná čára od puku dál.
    final trackFrom = head + thumbW / 2 + _trackGap + strokeWidth / 2;
    if (trackFrom < end) {
      canvas.drawLine(
        Offset(trackFrom, cy),
        Offset(end, cy),
        Paint()
          ..color = inactiveColor
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    // Průběh: vlna z kvadratických oblouků po půlvlnách (jako M3), amplituda
    // u puku plynule klesá k nule na posledních `taper` pixelech.
    final amp = waveAmplitude * amplitude.value;
    final active = Paint()
      ..color = activeColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final waveEnd = head - thumbW / 2;
    if (waveEnd > start) {
      if (amp <= 0.01 || wavelength <= 0) {
        canvas.drawLine(Offset(start, cy), Offset(waveEnd, cy), active);
      } else {
        canvas.drawPath(_wavePath(start, head, waveEnd, cy, amp), active);
      }
    }

    // Puk nakonec, přes začátek stopy i konec vlny.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(head, cy), width: thumbW, height: thumbH),
        Radius.circular(thumbW / 2),
      ),
      Paint()..color = thumbColor,
    );
  }

  /// Vlna od `start` do `waveEnd`. Oblouky jdou po půlvlnách s kontrolním
  /// bodem ve výšce 2× amplitudy (kvadratický oblouk tak vrcholí přesně na
  /// amplitudě), posunuté o fázi; obálka u puku je smoothstep.
  Path _wavePath(double start, double head, double waveEnd, double cy, double amp) {
    final half = wavelength / 2;
    final taper = math.min(wavelength, (head - start) * 0.5).clamp(1.0, double.infinity);
    final shift = phase.value * wavelength;
    double envelope(double x) {
      final t = ((head - x) / taper).clamp(0.0, 1.0);
      return t * t * (3 - 2 * t);
    }

    final path = Path();
    // Začátek oblouků zarovnaný na půlvlny posunuté o fázi; kreslí se jen
    // úsek od `start`, oblouky před ním se oříznou rozdělením prvního.
    var anchor = start - ((start + shift) % half);
    var sign = (((start + shift) / half).floor() % 2 == 0) ? -1.0 : 1.0;
    var first = true;
    while (anchor < waveEnd) {
      final next = anchor + half;
      final segStart = math.max(anchor, start);
      final segEnd = math.min(next, waveEnd);
      // Body oblouku vzorkované (oříznutí na začátku/konci a obálka by se
      // jedním kvadratickým obloukem nedaly přesně vyjádřit).
      const steps = 6;
      for (var i = 0; i <= steps; i++) {
        final x = segStart + (segEnd - segStart) * i / steps;
        final u = (x - anchor) / half; // 0..1 v rámci půlvlny
        // Kvadratický oblouk (0 -> 2·amp -> 0): y = 2·amp·2u(1-u) = 4·amp·u(1-u),
        // vrchol přesně na amplitudě.
        final y = cy + sign * amp * 4 * u * (1 - u) * envelope(x);
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      anchor = next;
      sign = -sign;
    }
    return path;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.value != value ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.thumbColor != thumbColor ||
      old.strokeWidth != strokeWidth ||
      old.thumbRadius != thumbRadius ||
      old.wavelength != wavelength ||
      old.waveAmplitude != waveAmplitude ||
      old.inset != inset ||
      old.phase != phase ||
      old.amplitude != amplitude ||
      old.dragging != dragging;
}
