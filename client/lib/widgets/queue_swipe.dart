import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/hints.dart';

import '../theme/glass_tokens.dart';

/// Swipe na řádku skladby jako v Apple Music: tah DOPRAVA = "Hrát jako
/// další" (začátek fronty), tah DOLEVA = "Na konec fronty". Delší tah doleva
/// (když je `onLater`) = "Poslechnout později" -- druhá úroveň jako v
/// poštovních appkách: jiná barva, ikona i popisek a silnější haptika, ať
/// je předem jasné, co se po puštění stane. Řádek se pod prstem posouvá a
/// odkrývá akci; akce se provede při puštění, řádek se pružinou vrátí zpět
/// (skladba ze seznamu nemizí).
class QueueSwipe extends StatefulWidget {
  const QueueSwipe({super.key, required this.child, required this.onPlayNext, required this.onPlayLast, this.onLater});

  final Widget child;
  final VoidCallback onPlayNext;
  final VoidCallback onPlayLast;
  final VoidCallback? onLater;

  @override
  State<QueueSwipe> createState() => _QueueSwipeState();
}

enum _Stage { none, queue, later }

class _QueueSwipeState extends State<QueueSwipe> with SingleTickerProviderStateMixin {
  late final AnimationController _dx = AnimationController.unbounded(vsync: this);
  static const _threshold = 72.0;
  static const _max = 96.0;
  static const _laterThreshold = 170.0;
  static const _laterMax = 200.0;
  static const _spring = SpringDescription(mass: 1, stiffness: 500, damping: 34);
  _Stage _stage = _Stage.none;

  @override
  void dispose() {
    _dx.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    final raw = _dx.value + d.delta.dx;
    final limit = raw < 0 && widget.onLater != null ? _laterMax : _max;
    // Za limitem gumička -- řádek neujede celou šířku.
    _dx.value = raw.abs() > limit ? limit * raw.sign + (raw - limit * raw.sign) * 0.2 : raw;
    final width = _dx.value.abs();
    final stage = width < _threshold
        ? _Stage.none
        : (_dx.value < 0 && widget.onLater != null && width >= _laterThreshold)
            ? _Stage.later
            : _Stage.queue;
    if (stage != _stage) {
      setState(() => _stage = stage);
      if (stage == _Stage.later) {
        HapticFeedback.mediumImpact();
      } else if (stage == _Stage.queue) {
        HapticFeedback.selectionClick();
      }
    }
  }

  HintsController? get _hints {
    try {
      return ProviderScope.containerOf(context, listen: false).read(hintsProvider.notifier);
    } catch (_) {
      return null; // mimo ProviderScope (testy widgetu)
    }
  }

  void _end(DragEndDetails d) {
    switch (_stage) {
      case _Stage.later:
        widget.onLater?.call();
        _hints?.used(Hint.laterSwipe);
      case _Stage.queue:
        _dx.value > 0 ? widget.onPlayNext() : widget.onPlayLast();
        _hints?.used(Hint.queueSwipe);
      case _Stage.none:
        break;
    }
    setState(() => _stage = _Stage.none);
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
          final later = _stage == _Stage.later;
          final armed = _stage != _Stage.none;
          final Color fill = later
              ? scheme.tertiary
              : armed
                  ? scheme.primary
                  : scheme.surfaceContainerHighest;
          final Color onFill = later
              ? scheme.onTertiary
              : armed
                  ? scheme.onPrimary
                  : scheme.onSurface;
          final IconData icon = later
              ? Symbols.schedule_rounded
              : next
                  ? Symbols.playlist_play_rounded
                  : Symbols.playlist_add_rounded;
          final String label = later
              ? 'Později'
              : next
                  ? 'Jako další'
                  : 'Na konec';
          // Nápověda, že tahem dál přijde "později" (jen doleva, před prahem).
          final hintLater = !next && widget.onLater != null && armed && !later;
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
                      color: fill.withValues(alpha: progress),
                      borderRadius: BorderRadius.circular(Expressive.cornerMedium),
                    ),
                    alignment: Alignment.center,
                    child: width < 40
                        ? null
                        : AnimatedSwitcher(
                            duration: Motion.press.duration,
                            switchInCurve: Motion.press,
                            transitionBuilder: (child, animation) => ScaleTransition(
                                scale: animation, child: FadeTransition(opacity: animation, child: child)),
                            // Úzký pruh: obsah se zmenší, nepřeteče.
                            child: Padding(
                              key: ValueKey(label),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(icon, color: onFill.withValues(alpha: progress), fill: armed ? 1 : 0),
                                    if (width >= 110) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        label,
                                        maxLines: 1,
                                        style: TextStyle(
                                          color: onFill.withValues(alpha: progress),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                    if (hintLater && width >= 110) ...[
                                      const SizedBox(width: 6),
                                      Icon(Symbols.keyboard_double_arrow_left_rounded,
                                          size: 16, color: onFill.withValues(alpha: 0.6)),
                                    ],
                                  ],
                                ),
                              ),
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
