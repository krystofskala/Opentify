import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Vlnovkový seek bar podle PixelPlayeru (github.com/brendmung/PixelPlayer,
/// `WavySliderExpressive.kt` + `PlayerSeekBar.kt`) -- vlastní port do Dartu,
/// protože Kotlin/Jetpack Compose (`LinearWavyProgressIndicator` z Material3
/// Expressive) nejde s Flutterem/Skiou sdílet přímo, žádný cross-framework
/// mechanismus neexistuje. Chová se stejně jako originál:
///   - odehraná část vlní (sinusoida), zbytek je plochá tečkovaná linka,
///   - amplituda vlnění doběhne na 0, když nic nehraje nebo se zrovna táhne,
///   - "puk" uprostřed se při tažení protáhne ze kolečka do svislé čárky.
/// `interactive: false` (viz `PlayerBar`) vypne gesta úplně -- jen vizuál,
/// žádné kradení tapů určených pro rozbalení Now Playing (viz
/// `AudioPlayerController`/`PlayerBar` dokumentační komentáře k tomuhle bugu).
class WavySeekBar extends StatefulWidget {
  const WavySeekBar({
    super.key,
    required this.progress,
    this.onChanged,
    this.onChangeEnd,
    this.isPlaying = false,
    this.interactive = true,
    this.activeColor = Colors.white,
    this.inactiveColor = const Color(0x4DFFFFFF),
    this.thumbColor = Colors.white,
    this.height = 28,
    this.strokeWidth = 3.5,
    this.thumbRadius = 6,
    this.wavelength = 22,
    this.waveAmplitude = 3.5,
  });

  /// 0..1, poloha přehrávání.
  final double progress;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final bool isPlaying;
  final bool interactive;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double height;
  final double strokeWidth;
  final double thumbRadius;
  final double wavelength;
  final double waveAmplitude;

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar> with TickerProviderStateMixin {
  late final AnimationController _phaseController;
  late final AnimationController _ampController;
  late final AnimationController _interactionController;

  bool _dragging = false;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    // Nekonečná fáze vlny -- běží pořád, ale je vidět jen když amplituda > 0,
    // stejně jako originální `SineWaveLine`/`WavySliderExpressive` (fáze
    // lineárně roste 0..2π, `animationDurationMillis`/`waveSpeed` v originále).
    _phaseController = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _ampController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.isPlaying && !_dragging ? 1 : 0,
    );
    _interactionController = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _syncAmplitudeTarget();
  }

  @override
  void didUpdateWidget(covariant WavySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncAmplitudeTarget();
  }

  void _syncAmplitudeTarget() {
    final target = widget.isPlaying && !_dragging ? 1.0 : 0.0;
    if ((_ampController.value - target).abs() > 0.001) {
      _ampController.animateTo(target, curve: Curves.easeInOut);
    }
  }

  @override
  void dispose() {
    _phaseController.dispose();
    _ampController.dispose();
    _interactionController.dispose();
    super.dispose();
  }

  double _valueForLocalX(double localX, double width) => (localX / width).clamp(0.0, 1.0);

  void _handleDragStart(double localX, double width) {
    if (!widget.interactive) return;
    setState(() {
      _dragging = true;
      _dragValue = _valueForLocalX(localX, width);
    });
    _interactionController.forward();
    _syncAmplitudeTarget();
    widget.onChanged?.call(_dragValue!);
  }

  void _handleDragUpdate(double localX, double width) {
    if (!widget.interactive || !_dragging) return;
    final value = _valueForLocalX(localX, width);
    setState(() => _dragValue = value);
    widget.onChanged?.call(value);
  }

  void _handleDragEnd() {
    if (!widget.interactive || !_dragging) return;
    final value = _dragValue ?? widget.progress;
    setState(() {
      _dragging = false;
      _dragValue = null;
    });
    _interactionController.reverse();
    _syncAmplitudeTarget();
    widget.onChangeEnd?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final displayedProgress = _dragging ? (_dragValue ?? widget.progress) : widget.progress;

    Widget bar = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return AnimatedBuilder(
          animation: Listenable.merge([_phaseController, _ampController, _interactionController]),
          builder: (context, _) => CustomPaint(
            size: Size(width, widget.height),
            painter: _WavySeekBarPainter(
              progress: displayedProgress,
              phase: _phaseController.value * 2 * math.pi,
              amplitudeFraction: _ampController.value,
              interactionFraction: _interactionController.value,
              activeColor: widget.activeColor,
              inactiveColor: widget.inactiveColor,
              thumbColor: widget.thumbColor,
              strokeWidth: widget.strokeWidth,
              thumbRadius: widget.thumbRadius,
              wavelength: widget.wavelength,
              maxAmplitude: widget.waveAmplitude,
            ),
          ),
        );
      },
    );

    if (!widget.interactive) {
      return SizedBox(height: widget.height, child: bar);
    }

    return SizedBox(
      height: widget.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          final box = context.findRenderObject() as RenderBox;
          _handleDragStart(details.localPosition.dx, box.size.width);
        },
        onTapUp: (_) => _handleDragEnd(),
        onHorizontalDragStart: (details) {
          final box = context.findRenderObject() as RenderBox;
          _handleDragStart(details.localPosition.dx, box.size.width);
        },
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox;
          _handleDragUpdate(details.localPosition.dx, box.size.width);
        },
        onHorizontalDragEnd: (_) => _handleDragEnd(),
        onHorizontalDragCancel: _handleDragEnd,
        child: bar,
      ),
    );
  }
}

class _WavySeekBarPainter extends CustomPainter {
  _WavySeekBarPainter({
    required this.progress,
    required this.phase,
    required this.amplitudeFraction,
    required this.interactionFraction,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.strokeWidth,
    required this.thumbRadius,
    required this.wavelength,
    required this.maxAmplitude,
  });

  final double progress;
  final double phase;
  final double amplitudeFraction;
  final double interactionFraction;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double strokeWidth;
  final double thumbRadius;
  final double wavelength;
  final double maxAmplitude;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final amplitude = amplitudeFraction * maxAmplitude;

    // Puk uprostřed morphuje z kolečka (idle) do svislé čárky (tažení) --
    // stejný lerp jako `currentWidth`/`currentHeight` ve `WavySliderExpressive`.
    final thumbWidth = _lerp(thumbRadius * 2, strokeWidth * 1.4, interactionFraction);
    final thumbHeight = _lerp(thumbRadius * 2, size.height * 0.85, interactionFraction);
    final rawThumbX = progress * size.width;
    final minCenter = thumbWidth / 2;
    final maxCenter = (size.width - thumbWidth / 2).clamp(minCenter, size.width);
    final thumbX = rawThumbX.clamp(minCenter, maxCenter);

    // Mezera kolem puku, ať vlna/linka nekreslí přes něj -- roste s
    // interactionFraction stejně jako `dynamicGapSize` v originále.
    final gap = _lerp(thumbRadius + 3, thumbWidth / 2 + 4, interactionFraction);

    _drawSegment(canvas, size, 0, (thumbX - gap).clamp(0.0, size.width), centerY, amplitude, activeColor, active: true);
    _drawSegment(
        canvas, size, (thumbX + gap).clamp(0.0, size.width), size.width, centerY, amplitude, inactiveColor,
        active: false);

    final thumbPaint = Paint()..color = thumbColor;
    final rect = Rect.fromCenter(center: Offset(thumbX, centerY), width: thumbWidth, height: thumbHeight);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(thumbWidth / 2)), thumbPaint);
  }

  void _drawSegment(
    Canvas canvas,
    Size size,
    double startX,
    double endX,
    double centerY,
    double amplitude,
    Color color, {
    required bool active,
  }) {
    if (endX - startX < 1) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (amplitude < 0.05) {
      canvas.drawLine(Offset(startX, centerY), Offset(endX, centerY), paint);
      return;
    }

    // `x` zůstává v absolutních souřadnicích celého baru (ne relativních k
    // segmentu), takže vlna zůstává jedna spojitá sinusoida přes celou šířku
    // s "vystřiženou" mezerou u puku -- přesně vizuální chování originálu.
    final path = Path();
    const sampleStep = 3.0;
    var first = true;
    for (double x = startX; x <= endX; x += sampleStep) {
      final theta = (x / wavelength) * 2 * math.pi + phase;
      final y = centerY + amplitude * math.sin(theta);
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }
    final thetaEnd = (endX / wavelength) * 2 * math.pi + phase;
    path.lineTo(endX, centerY + amplitude * math.sin(thetaEnd));
    canvas.drawPath(path, paint);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(covariant _WavySeekBarPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.phase != phase ||
        oldDelegate.amplitudeFraction != amplitudeFraction ||
        oldDelegate.interactionFraction != interactionFraction ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
