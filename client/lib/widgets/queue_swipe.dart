import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_tokens.dart';

/// Swipe na řádku skladby jako v Apple Music: tah DOPRAVA = "Hrát jako
/// další" (začátek fronty), tah DOLEVA = "Na konec fronty". Řádek se pod
/// prstem posouvá a odkrývá tónovanou akci; po překročení prahu drobná
/// haptika a akce se provede při puštění, řádek se pružinou vrátí zpět
/// (skladba ze seznamu nemizí).
class QueueSwipe extends StatefulWidget {
  const QueueSwipe({super.key, required this.child, required this.onPlayNext, required this.onPlayLast});

  final Widget child;
  final VoidCallback onPlayNext;
  final VoidCallback onPlayLast;

  @override
  State<QueueSwipe> createState() => _QueueSwipeState();
}

class _QueueSwipeState extends State<QueueSwipe> with SingleTickerProviderStateMixin {
  late final AnimationController _dx = AnimationController.unbounded(vsync: this);
  static const _threshold = 72.0;
  static const _max = 96.0;
  static const _spring = SpringDescription(mass: 1, stiffness: 500, damping: 34);
  bool _armed = false;

  @override
  void dispose() {
    _dx.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    final raw = _dx.value + d.delta.dx;
    // Za prahem gumička -- řádek neujede celou šířku.
    _dx.value = raw.abs() > _max ? _max * raw.sign + (raw - _max * raw.sign) * 0.2 : raw;
    final armed = _dx.value.abs() >= _threshold;
    if (armed != _armed) {
      setState(() => _armed = armed);
      if (armed) HapticFeedback.selectionClick();
    }
  }

  void _end(DragEndDetails d) {
    if (_armed) {
      if (_dx.value > 0) {
        widget.onPlayNext();
      } else {
        widget.onPlayLast();
      }
    }
    setState(() => _armed = false);
    _springBack(d.velocity.pixelsPerSecond.dx);
  }

  // Pružina končí jen "skoro" na nule -- dojet na přesnou nulu, jinak zůstal
  // pod řádkem zbytek podbarvení (živě nahlášeno).
  Future<void> _springBack(double velocity) async {
    await _dx.animateWith(SpringSimulation(_spring, _dx.value, 0, velocity));
    if (mounted) _dx.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => _springBack(0),
      child: AnimatedBuilder(
        animation: _dx,
        builder: (context, child) {
          final dx = _dx.value;
          final next = dx > 0;
          final width = dx.abs();
          final progress = (width / _threshold).clamp(0.0, 1.0);
          // Řádek je průhledný -- akce se kreslí JEN v odkrytém pruhu vedle
          // posunutého řádku (jako Apple Music), jinak prosvítala přes text.
          return Stack(
            children: [
              if (width >= 1)
                Positioned(
                  top: 4,
                  bottom: 4,
                  left: next ? 4 : null,
                  right: next ? null : 4,
                  width: math.max(0.0, width - 8),
                  child: AnimatedContainer(
                    duration: Motion.state.duration,
                    curve: Motion.state,
                    decoration: BoxDecoration(
                      color: (_armed ? scheme.primary : scheme.surfaceContainerHighest).withValues(alpha: progress),
                      borderRadius: BorderRadius.circular(Expressive.cornerMedium),
                    ),
                    alignment: Alignment.center,
                    child: width < 40
                        ? null
                        : Icon(
                            next ? Symbols.playlist_play_rounded : Symbols.playlist_add_rounded,
                            color: (_armed ? scheme.onPrimary : scheme.onSurface).withValues(alpha: progress),
                            fill: _armed ? 1 : 0,
                          ),
                  ),
                ),
              Transform.translate(offset: Offset(dx, 0), child: child),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}
