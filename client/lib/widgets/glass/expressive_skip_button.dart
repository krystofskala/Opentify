import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_tokens.dart';

/// Další/Předchozí v jazyce M3 Expressive (jako PixelPlay): tónový squircle,
/// který se při stisku pružinou roztáhne a zhranatí, a šipka po klepnutí
/// "prolétne" -- odjede ve směru přeskočení a nová přijede z druhé strany.
class ExpressiveSkipButton extends StatefulWidget {
  const ExpressiveSkipButton({super.key, required this.forward, required this.onPressed, this.color = Colors.white});

  final bool forward;
  final VoidCallback? onPressed;
  final Color color;

  @override
  State<ExpressiveSkipButton> createState() => _ExpressiveSkipButtonState();
}

class _ExpressiveSkipButtonState extends State<ExpressiveSkipButton> with SingleTickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  bool _pressed = false;

  static const double _width = 58;
  static const double _pressedWidth = 70;
  static const double _height = 56;

  @override
  void dispose() {
    _fly.dispose();
    super.dispose();
  }

  void _tap() {
    final onPressed = widget.onPressed;
    if (onPressed == null) return;
    HapticFeedback.lightImpact();
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) _fly.forward(from: 0);
    onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final fg = widget.color.withValues(alpha: enabled ? 1 : 0.35);
    final dir = widget.forward ? 1.0 : -1.0;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.forward ? 'Další skladba' : 'Předchozí skladba',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _tap,
        child: SizedBox(
          width: _pressedWidth,
          height: _height,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.enter.duration,
              curve: Motion.enter,
              width: _pressed ? _pressedWidth : _width,
              height: _height,
              decoration: ShapeDecoration(
                color: widget.color.withValues(alpha: _pressed ? 0.22 : 0.12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_pressed ? 16 : 26)),
              ),
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _fly,
                  builder: (context, child) {
                    // 0..0.45 stará šipka odjede, 0.45..1 nová přijede
                    // (s lehkým dojezdem přes cíl).
                    final t = _fly.value;
                    final double dx;
                    final double opacity;
                    if (!_fly.isAnimating || t == 0) {
                      dx = 0;
                      opacity = 1;
                    } else if (t < 0.45) {
                      final p = Curves.easeInCubic.transform(t / 0.45);
                      dx = dir * 28 * p;
                      opacity = 1 - p;
                    } else {
                      final p = Curves.easeOutBack.transform((t - 0.45) / 0.55);
                      dx = -dir * 28 * (1 - p);
                      opacity = ((t - 0.45) / 0.25).clamp(0.0, 1.0);
                    }
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: Opacity(opacity: opacity, child: child),
                    );
                  },
                  child: Icon(
                    widget.forward ? Symbols.skip_next_rounded : Symbols.skip_previous_rounded,
                    size: 32,
                    fill: 1,
                    color: fg,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
