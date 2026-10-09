import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Theme;

/// Rychlé posouvání dlouhých seznamů myší a klávesnicí (Míša, 8. 10.:
/// u hodně dlouhého playlistu šlo jen kolečkem):
///   - klik prostředním tlačítkem = automatický posun jako v prohlížeči
///     (rychlost podle vzdálenosti kurzoru od místa kliknutí; další klik,
///     Esc nebo puštění po tažení ho ukončí),
///   - PgUp / PgDn o stránku, Home / End na začátek / konec,
///   - mezerník = přehrát / pozastavit (`onSpace`; jako Spotify).
/// Posouvá seznam pod kurzorem (bez fokusu -- Flutter by klávesy jinak
/// poslal jen seznamu, který má fokus). V textovém poli klávesy nechává.
class DesktopScrollAssist extends StatefulWidget {
  const DesktopScrollAssist({super.key, required this.child, this.onSpace, this.onUsed, this.onLongWheel});
  final Widget child;
  final VoidCallback? onSpace;

  /// Použita klávesa (PgUp/PgDn/Home/End) nebo klik kolečkem (tipy k funkcím).
  final VoidCallback? onUsed;

  /// Dlouhé točení kolečkem v dlouhém seznamu (tipy k funkcím).
  final VoidCallback? onLongWheel;

  @override
  State<DesktopScrollAssist> createState() => _DesktopScrollAssistState();
}

class _DesktopScrollAssistState extends State<DesktopScrollAssist> with SingleTickerProviderStateMixin {
  Offset? _pointer;
  ScrollPosition? _auto;
  Offset _origin = Offset.zero;
  DateTime _autoStartedAt = DateTime.now();
  bool _movedWhileHeld = false;
  late final Ticker _ticker = createTicker(_tick);
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ticker.dispose();
    super.dispose();
  }

  /// Svislý seznam pod bodem (nejvnitřnější, který se dá posouvat) --
  /// vodorovné řady na Domů se přeskočí.
  ScrollPosition? _positionAt(Offset global) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, global, View.of(context).viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderViewportBase && target.axis == Axis.vertical) {
        final offset = target.offset;
        if (offset is ScrollPosition && offset.hasContentDimensions && offset.maxScrollExtent > offset.minScrollExtent) {
          return offset;
        }
      }
    }
    return null;
  }

  /// Co posouvat: seznam pod kurzorem, jinak hlavní (největší viditelný)
  /// seznam stránky -- kurzor nad hlavičkou, přehrávačem nebo prázdným
  /// místem dřív nedělal nic (živě 8. 10.: „funguje jen někdy“). Hledá se
  /// zkusmo v mřížce bodů přes obrazovku: najde jen to, co je opravdu
  /// vidět (ne skryté karty a stránky pod ní).
  ScrollPosition? _scrollTarget() {
    final p = _pointer;
    if (p != null) {
      final under = _positionAt(p);
      if (under != null) return under;
    }
    final size = MediaQuery.sizeOf(context);
    ScrollPosition? best;
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 3; x++) {
        final found = _positionAt(Offset(size.width * x / 4, size.height * y / 6));
        if (found != null && (best == null || found.viewportDimension > best.viewportDimension)) best = found;
      }
    }
    return best;
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      // V textovém poli je mezera mezera; držení nepřepíná dokola.
      if (event is KeyRepeatEvent || widget.onSpace == null) return false;
      if (FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null) return false;
      widget.onSpace!();
      return true;
    }
    if (key == LogicalKeyboardKey.escape && _auto != null) {
      _stopAuto();
      return true;
    }
    if (key != LogicalKeyboardKey.pageDown &&
        key != LogicalKeyboardKey.pageUp &&
        key != LogicalKeyboardKey.home &&
        key != LogicalKeyboardKey.end) {
      return false;
    }
    // Textové pole si Home / End / PgUp nechá.
    if (FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null) return false;
    final position = _scrollTarget();
    if (position == null) return false;
    widget.onUsed?.call();
    final page = position.viewportDimension * 0.85;
    final to = switch (key) {
      LogicalKeyboardKey.pageDown => position.pixels + page,
      LogicalKeyboardKey.pageUp => position.pixels - page,
      LogicalKeyboardKey.home => position.minScrollExtent,
      _ => position.maxScrollExtent,
    }
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final far = (to - position.pixels).abs() > position.viewportDimension * 3;
    // Daleký skok (Home / End v dlouhém seznamu) hned, jinak plynule.
    if (far) {
      position.jumpTo(to);
    } else {
      position.animateTo(to, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
    return true;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointer = event.position;
    if (_auto != null) {
      _stopAuto();
      return;
    }
    if (event.kind != PointerDeviceKind.mouse || event.buttons & kMiddleMouseButton == 0) return;
    final position = _scrollTarget();
    if (position == null) return;
    widget.onUsed?.call();
    setState(() {
      _auto = position;
      _origin = event.position;
      _autoStartedAt = DateTime.now();
      _movedWhileHeld = false;
    });
    _lastTick = Duration.zero;
    _ticker.start();
  }

  final List<DateTime> _wheel = [];

  /// Hodně kolečka za minutu v seznamu delším než ~20 obrazovek.
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || widget.onLongWheel == null) return;
    final now = DateTime.now();
    _wheel.add(now);
    _wheel.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_wheel.length < 150) return;
    final position = _positionAt(event.position);
    if (position != null && position.maxScrollExtent > position.viewportDimension * 20) {
      _wheel.clear();
      widget.onLongWheel!();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_auto == null) return;
    // Držení a tažení (jako v prohlížeči): puštění končí. Krátký klik:
    // posun běží, dokud se znovu neklikne.
    final held = DateTime.now().difference(_autoStartedAt) > const Duration(milliseconds: 450);
    if (_movedWhileHeld || held) _stopAuto();
  }

  void _onMove(Offset position, {bool pressed = false}) {
    _pointer = position;
    if (_auto != null && pressed && (position - _origin).distance > 16) _movedWhileHeld = true;
  }

  static const _dead = 15.0;
  int _direction = 0;

  void _stopAuto() {
    _ticker.stop();
    if (mounted) {
      setState(() {
        _auto = null;
        _direction = 0;
      });
    }
  }

  void _tick(Duration elapsed) {
    final position = _auto;
    final pointer = _pointer;
    if (position == null || pointer == null) return;
    if (!position.hasPixels) return _stopAuto();
    final dt = _lastTick == Duration.zero ? 0.0 : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final d = pointer.dy - _origin.dy;
    final direction = d.abs() <= _dead ? 0 : d.sign.toInt();
    if (direction != _direction) setState(() => _direction = direction);
    if (direction == 0 || dt <= 0) return;
    // Jako Chrome: rychlost roste rovnoměrně se vzdáleností od místa kliknutí.
    final speed = math.min((d.abs() - _dead) * 8.0, 12000.0) * d.sign;
    final to = (position.pixels + speed * dt).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if (to != position.pixels) position.jumpTo(to);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _onWheel,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerMove: (e) => _onMove(e.position, pressed: true),
      onPointerHover: (e) => _onMove(e.position),
      child: MouseRegion(
        // Kurzor jako v prohlížeči: na místě kliknutí „posun“, jinak šipka směru.
        cursor: _auto == null
            ? MouseCursor.defer
            : switch (_direction) {
                1 => SystemMouseCursors.resizeDown,
                -1 => SystemMouseCursors.resizeUp,
                _ => SystemMouseCursors.allScroll,
              },
        onHover: (e) => _pointer = e.position,
        child: Stack(
          children: [
            widget.child,
            if (_auto != null)
              Positioned(
                left: _origin.dx - 14,
                top: _origin.dy - 14,
                // Značka místa kliknutí jako v prohlížeči: kolečko se šipkami
                // nahoru / dolů a tečkou uprostřed.
                child: IgnorePointer(
                  child: CustomPaint(
                    size: const Size.square(28),
                    painter: _AutoscrollMark(
                      fill: theme.colorScheme.surface.withValues(alpha: 0.92),
                      ink: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AutoscrollMark extends CustomPainter {
  _AutoscrollMark({required this.fill, required this.ink});
  final Color fill;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r - 1, Paint()..color = fill);
    canvas.drawCircle(c, r - 1, Paint()
      ..color = ink.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
    final p = Paint()..color = ink;
    canvas.drawCircle(c, 2, p);
    canvas.drawPath(Path()
      ..moveTo(c.dx, c.dy - r + 4)
      ..lineTo(c.dx - 4.5, c.dy - r + 10)
      ..lineTo(c.dx + 4.5, c.dy - r + 10)
      ..close(), p);
    canvas.drawPath(Path()
      ..moveTo(c.dx, c.dy + r - 4)
      ..lineTo(c.dx - 4.5, c.dy + r - 10)
      ..lineTo(c.dx + 4.5, c.dy + r - 10)
      ..close(), p);
  }

  @override
  bool shouldRepaint(_AutoscrollMark old) => old.fill != fill || old.ink != ink;
}
