import 'package:flutter/material.dart';

/// Obsah svislých seznamů se u horní hrany postupně rozplyne do pozadí, jak
/// odjíždí pod lištu -- místo šedého skleněného pruhu, který se dřív objevil
/// za nadpisem při scrollu (živě nahlášeno: "zašedlé/zablokované nahoře").
/// V klidu (nahoře) se nic nemaže; rozplynutí naběhne s prvními pixely scrollu.
class TopFadeScrollBehavior extends MaterialScrollBehavior {
  const TopFadeScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    final base = super.buildOverscrollIndicator(context, child, details);
    if (details.direction != AxisDirection.down) return base;
    return _TopFade(child: base);
  }
}

class _TopFade extends StatelessWidget {
  const _TopFade({required this.child});

  final Widget child;

  static const double _fade = 28;

  @override
  Widget build(BuildContext context) {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null) return child;
    return ListenableBuilder(
      listenable: position,
      builder: (context, child) {
        final pixels = position.hasPixels ? position.pixels : 0.0;
        final t = (pixels / _fade).clamp(0.0, 1.0);
        if (t <= 0) return child!;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final stop = (_fade / rect.height).clamp(0.0, 1.0);
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 1 - t), Colors.black],
              stops: [0, stop],
            ).createShader(rect);
          },
          child: child,
        );
      },
      child: child,
    );
  }
}
