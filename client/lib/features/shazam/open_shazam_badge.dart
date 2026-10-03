import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../theme/design_tokens.dart';

/// Značka „Open Shazam“ -- skladba rozpoznaná v appce (Poslechnout později,
/// výsledek rozpoznání).
class OpenShazamBadge extends StatelessWidget {
  const OpenShazamBadge({super.key, this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = large ? 13.0 : 10.5;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 10 : 6, vertical: large ? 4 : 1.5),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(AppRadii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.graphic_eq_rounded, size: size + 2, color: scheme.onTertiaryContainer),
          SizedBox(width: large ? 5 : 3),
          Text(
            'Open Shazam',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              color: scheme.onTertiaryContainer,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
