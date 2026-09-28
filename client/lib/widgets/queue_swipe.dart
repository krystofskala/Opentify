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
  static const _max = 120.0;
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
    _dx.animateWith(SpringSimulation(_spring, _dx.value, 0, d.velocity.pixelsPerSecond.dx));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => _dx.animateWith(SpringSimulation(_spring, _dx.value, 0, 0)),
      child: AnimatedBuilder(
        animation: _dx,
        builder: (context, child) {
          final dx = _dx.value;
          final next = dx > 0;
          final progress = (dx.abs() / _threshold).clamp(0.0, 1.0);
          return Stack(
            children: [
              if (dx != 0)
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: Motion.state.duration,
                    curve: Motion.state,
                    decoration: BoxDecoration(
                      color: (_armed ? scheme.primaryContainer : scheme.surfaceContainerHigh)
                          .withValues(alpha: 0.5 + 0.4 * progress),
                      borderRadius: BorderRadius.circular(Expressive.cornerMedium),
                    ),
                    alignment: next ? Alignment.centerLeft : Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Opacity(
                      opacity: progress,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            next ? Symbols.playlist_play_rounded : Symbols.queue_music_rounded,
                            color: _armed ? scheme.onPrimaryContainer : scheme.onSurface,
                            fill: _armed ? 1 : 0,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            next ? 'Hrát jako další' : 'Na konec fronty',
                            style: TextStyle(
                              color: _armed ? scheme.onPrimaryContainer : scheme.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
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
