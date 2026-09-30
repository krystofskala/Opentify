import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';


/// Předchozí · Přehrát · Další jako spojená skupina tlačítek M3 Expressive
/// (jako PixelPlay, https://m3.material.io/blog/building-with-m3-expressive):
/// stejná výška, těsné mezery, kapslové tvary. Stisknuté tlačítko se
/// pružinou roztáhne do strany a sousedi mu uhnou (šířka skupiny zůstává),
/// rohy se při stisku zhranatí. Šipka po přeskočení "prolétne" ve směru.
class ExpressivePlayerGroup extends StatefulWidget {
  const ExpressivePlayerGroup({
    super.key,
    required this.isPlaying,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.playColor,
    required this.playIconColor,
    this.playChild,
    this.height = 68,
  });

  final bool isPlaying;
  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;
  final Color playColor;
  final Color playIconColor;

  /// Náhrada ikony uprostřed (načítání/stahování).
  final Widget? playChild;
  final double height;

  @override
  State<ExpressivePlayerGroup> createState() => _ExpressivePlayerGroupState();
}

class _ExpressivePlayerGroupState extends State<ExpressivePlayerGroup> with TickerProviderStateMixin {
  late final AnimationController _flyPrev = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final AnimationController _flyNext = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  // "Puls" každého tlačítka (0 = klid, 1 = roztažené). Neomezený, ať
  // pružina při návratu může lehce přestřelit (typický Expressive dojezd).
  late final List<AnimationController> _pulse = [
    for (var i = 0; i < 3; i++) AnimationController.unbounded(vsync: this),
  ];
  final List<bool> _holding = [false, false, false];

  static const double _gap = 6;
  // Přehrát je širší; stisknuté se roztáhne o 65 % a sousedi uhnou.
  static const _weights = [1.0, 1.35, 1.0];
  static const double _grow = 0.65;
  static const _back = SpringDescription(mass: 1, stiffness: 320, damping: 16);

  @override
  void dispose() {
    _flyPrev.dispose();
    _flyNext.dispose();
    for (final c in _pulse) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _reduce => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  VoidCallback? _callback(int i) => switch (i) {
        0 => widget.onPrevious,
        1 => widget.onPlayPause,
        _ => widget.onNext,
      };

  void _down(int i) {
    if (_reduce) return;
    _holding[i] = true;
    _pulse[i].animateTo(1, duration: const Duration(milliseconds: 140), curve: Curves.easeOutCubic);
  }

  /// Po puštění (nebo rychlém klepnutí) tlačítko nejdřív dorazí do plného
  /// roztažení -- i krátké ťuknutí je tak vidět -- a pak pružinou zpět.
  Future<void> _release(int i) async {
    _holding[i] = false;
    if (_reduce) return;
    final c = _pulse[i];
    if (c.value < 0.98) {
      await c.animateTo(1, duration: Duration(milliseconds: (140 * (1 - c.value)).round() + 40), curve: Curves.easeOutCubic);
    }
    if (!mounted || _holding[i]) return;
    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (!mounted || _holding[i]) return;
    c.animateWith(SpringSimulation(_back, c.value, 0, 0));
  }

  void _tap(int i) {
    final cb = _callback(i);
    if (cb == null) return;
    HapticFeedback.lightImpact();
    if (!_reduce) {
      if (i == 0) _flyPrev.forward(from: 0);
      if (i == 2) _flyNext.forward(from: 0);
    }
    cb();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final total = constraints.maxWidth - 2 * _gap;
      return SizedBox(
        height: widget.height,
        child: AnimatedBuilder(
          animation: Listenable.merge(_pulse),
          builder: (context, _) {
            final weights = [
              for (var i = 0; i < 3; i++) _weights[i] * (1 + _grow * _pulse[i].value),
            ];
            final sum = weights.fold<double>(0, (a, b) => a + b);
            return Row(
              children: [
                _item(0, total * weights[0] / sum),
                const SizedBox(width: _gap),
                _item(1, total * weights[1] / sum),
                const SizedBox(width: _gap),
                _item(2, total * weights[2] / sum),
              ],
            );
          },
        ),
      );
    });
  }

  Widget _item(int i, double width) {
    final enabled = _callback(i) != null;
    final p = _pulse[i].value;
    final pc = p.clamp(0.0, 1.0);
    final isPlay = i == 1;
    final h = widget.height;
    // Kapsle v klidu, roztažené = hranatější. Přehrát: hraje = zaoblený
    // čtverec, pauza = kapsle (tvar ukazuje stav jako v PixelPlay).
    final rest = isPlay ? (widget.isPlaying ? h * 0.32 : h / 2) : h / 2;
    final radius = lerpDouble(rest, h * 0.24, pc)!;
    final color = isPlay ? widget.playColor : Colors.white.withValues(alpha: 0.14 + 0.12 * pc);
    // Šipky se vyboulí směrem přeskočení (Předchozí doleva, Další doprava).
    final dir = i == 0 ? -1.0 : (i == 2 ? 1.0 : 0.0);
    final Widget icon;
    if (isPlay) {
      icon = widget.playChild ??
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
            child: Icon(
              widget.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
              key: ValueKey(widget.isPlaying),
              size: 40,
              fill: 1,
              color: widget.playIconColor,
            ),
          );
    } else {
      icon = _Fly(
        animation: i == 0 ? _flyPrev : _flyNext,
        direction: dir,
        child: Icon(
          i == 0 ? Symbols.skip_previous_rounded : Symbols.skip_next_rounded,
          size: 32,
          fill: 1,
          color: Colors.white.withValues(alpha: enabled ? 1 : 0.35),
        ),
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: switch (i) {
        0 => 'Předchozí skladba',
        1 => widget.isPlaying ? 'Pozastavit' : 'Přehrát',
        _ => 'Další skladba',
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _down(i) : null,
        onTapUp: enabled ? (_) => _release(i) : null,
        onTapCancel: () => _release(i),
        onTap: () => _tap(i),
        child: Transform.translate(
          offset: Offset(dir * 7 * p, 0),
          child: Transform.scale(
            scaleY: 1 + 0.07 * p,
            child: Container(
              width: width,
              height: h,
              decoration: ShapeDecoration(
                color: color,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
              ),
              child: ClipRect(child: Center(child: icon)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Šipka odjede ve směru přeskočení a nová přijede z druhé strany.
class _Fly extends StatelessWidget {
  const _Fly({required this.animation, required this.direction, required this.child});

  final AnimationController animation;
  final double direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        if (!animation.isAnimating || t == 0) return child!;
        final double dx;
        final double opacity;
        if (t < 0.45) {
          final p = Curves.easeInCubic.transform(t / 0.45);
          dx = direction * 30 * p;
          opacity = 1 - p;
        } else {
          final p = Curves.easeOutBack.transform((t - 0.45) / 0.55);
          dx = -direction * 30 * (1 - p);
          opacity = ((t - 0.45) / 0.25).clamp(0.0, 1.0);
        }
        return Transform.translate(offset: Offset(dx, 0), child: Opacity(opacity: opacity, child: child));
      },
      child: child,
    );
  }
}
