import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:material_symbols_icons/symbols.dart';

/// Rychlé posouvání dlouhých seznamů myší a klávesnicí (Míša, 8. 10.:
/// u hodně dlouhého playlistu šlo jen kolečkem):
///   - klik prostředním tlačítkem = automatický posun jako v prohlížeči
///     (rychlost podle vzdálenosti kurzoru od místa kliknutí; další klik,
///     Esc nebo puštění po tažení ho ukončí),
///   - PgUp / PgDn o stránku, Home / End na začátek / konec.
/// Posouvá seznam pod kurzorem (bez fokusu -- Flutter by klávesy jinak
/// poslal jen seznamu, který má fokus). V textovém poli klávesy nechává.
class DesktopScrollAssist extends StatefulWidget {
  const DesktopScrollAssist({super.key, required this.child});
  final Widget child;

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

  Offset get _target {
    final p = _pointer;
    if (p != null) return p;
    final size = MediaQuery.sizeOf(context);
    return Offset(size.width / 2, size.height / 2);
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final key = event.logicalKey;
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
    final position = _positionAt(_target);
    if (position == null) return false;
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
    final position = _positionAt(event.position);
    if (position == null) return;
    setState(() {
      _auto = position;
      _origin = event.position;
      _autoStartedAt = DateTime.now();
      _movedWhileHeld = false;
    });
    _lastTick = Duration.zero;
    _ticker.start();
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

  void _stopAuto() {
    _ticker.stop();
    if (mounted) setState(() => _auto = null);
  }

  void _tick(Duration elapsed) {
    final position = _auto;
    final pointer = _pointer;
    if (position == null || pointer == null) return;
    if (!position.hasPixels) return _stopAuto();
    final dt = _lastTick == Duration.zero ? 0.0 : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final d = pointer.dy - _origin.dy;
    const dead = 12.0;
    if (d.abs() <= dead || dt <= 0) return;
    // Dál od místa kliknutí = rychleji (mírně víc než lineárně).
    final speed = math.min(math.pow(d.abs() - dead, 1.35) * 3.0, 9000.0) * d.sign;
    final to = (position.pixels + speed * dt).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if (to != position.pixels) position.jumpTo(to);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerMove: (e) => _onMove(e.position, pressed: true),
      onPointerHover: (e) => _onMove(e.position),
      child: MouseRegion(
        cursor: _auto == null ? MouseCursor.defer : SystemMouseCursors.allScroll,
        onHover: (e) => _pointer = e.position,
        child: Stack(
          children: [
            widget.child,
            if (_auto != null)
              Positioned(
                left: _origin.dx - 16,
                top: _origin.dy - 16,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.colorScheme.outline),
                    ),
                    child: SizedBox.square(
                      dimension: 32,
                      child: Icon(Symbols.unfold_more_rounded, size: 20, color: theme.colorScheme.onSurface),
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
