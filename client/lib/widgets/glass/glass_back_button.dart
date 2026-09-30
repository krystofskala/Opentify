import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'glass_pressable.dart';

/// Jediné tlačítko Zpět v appce: kruh 44 px (HIG minimum), jemný tónový
/// podklad, šipka. `onImage` = nad fotkou (hlavička alba/interpreta) --
/// tmavý podklad a bílá šipka, jinak barvy motivu.
class GlassBackButton extends StatelessWidget {
  const GlassBackButton({super.key, this.onPressed, this.onImage = false, this.icon = Symbols.arrow_back_rounded});

  final VoidCallback? onPressed;
  final bool onImage;
  final IconData icon;

  static const double size = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = onImage ? Colors.black.withValues(alpha: 0.32) : scheme.onSurface.withValues(alpha: 0.08);
    final fg = onImage ? Colors.white : scheme.onSurface;
    return Semantics(
      button: true,
      label: 'Zpět',
      child: GlassPressable(
        onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
        shape: const CircleBorder(),
        minSize: const Size.square(size),
        child: DecoratedBox(
          decoration: ShapeDecoration(shape: const CircleBorder(), color: bg),
          child: SizedBox.square(dimension: size, child: Icon(icon, color: fg, size: 22)),
        ),
      ),
    );
  }
}
