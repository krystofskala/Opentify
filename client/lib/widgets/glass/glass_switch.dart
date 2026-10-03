import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import '../../theme/design_tokens.dart';

/// iOS přepínač (51×31, palec 27). HIG Toggles
/// (https://developer.apple.com/design/human-interface-guidelines/toggles):
/// - "Use the switch toggle style only in a list row" → používej přes
///   [GlassSwitchRow]; mimo seznam `GlassToggleButton`.
/// - Zapnuto = tónový akcent appky (`colorScheme.primary`, mix s M3
///   Expressive -- HIG dovoluje "your app's accent color" místo zelené).
/// - Stav není jen barvou: palec se posouvá + (jako iOS "On/Off labels")
///   zapnutá stopa má výraznou výplň, vypnutá jen jemnou.
/// Dotyková plocha 44 na výšku.
class GlassSwitch extends StatefulWidget {
  const GlassSwitch({super.key, required this.value, required this.onChanged, this.activeColor, this.semanticLabel});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final String? semanticLabel;

  static const double width = 51;
  static const double height = 31;
  static const double thumb = 27;

  @override
  State<GlassSwitch> createState() => _GlassSwitchState();
}

class _GlassSwitchState extends State<GlassSwitch> {
  bool _pressed = false;

  bool get _enabled => widget.onChanged != null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onColor = widget.activeColor ?? Theme.of(context).colorScheme.primary;
    final offColor = (isDark ? Colors.white : Colors.black).withValues(alpha: isDark ? 0.16 : 0.09);
    // Při stisku se palec protáhne (jako iOS) -- zpětná vazba bez změny barvy.
    final thumbWidth = _pressed ? GlassSwitch.thumb + 7 : GlassSwitch.thumb;
    const inset = (GlassSwitch.height - GlassSwitch.thumb) / 2;

    return Semantics(
      toggled: widget.value,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: _enabled ? () => widget.onChanged!(!widget.value) : null,
          onHorizontalDragEnd: _enabled
              ? (details) {
                  final v = details.primaryVelocity ?? 0;
                  if (v > 0 && !widget.value) widget.onChanged!(true);
                  if (v < 0 && widget.value) widget.onChanged!(false);
                }
              : null,
          child: SizedBox(
            height: GlassTokens.minHitTarget,
            width: GlassSwitch.width,
            child: Center(
              child: AnimatedOpacity(
                opacity: _enabled ? 1 : GlassTokens.disabledOpacity,
                duration: GlassTokens.stateDuration,
                child: AnimatedContainer(
                  duration: Motion.state.duration,
                  curve: Motion.state,
                  width: GlassSwitch.width,
                  height: GlassSwitch.height,
                  decoration: BoxDecoration(
                    color: widget.value ? onColor : offColor,
                    borderRadius: BorderRadius.circular(GlassSwitch.height / 2),
                  ),
                  child: Stack(
                    children: [
                      AnimatedPositioned(
                        duration: Motion.press.duration,
                        curve: Motion.press,
                        top: inset,
                        left: widget.value ? GlassSwitch.width - thumbWidth - inset : inset,
                        width: thumbWidth,
                        height: GlassSwitch.thumb,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(GlassSwitch.thumb / 2),
                            boxShadow: const [
                              BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 3)),
                              BoxShadow(color: Color(0x0F000000), blurRadius: 1, offset: Offset(0, 1)),
                            ],
                          ),
                        ),
                      ),
                    ],
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

/// Řádek seznamu s přepínačem -- jediné místo, kde má přepínač být
/// (HIG Toggles). Klepnutí kamkoliv na řádek přepne.
class GlassSwitchRow extends StatelessWidget {
  const GlassSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.activeColor,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: GlassTokens.minHitTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: theme.textTheme.bodyLarge),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                GlassSwitch(value: value, onChanged: onChanged, activeColor: activeColor, semanticLabel: title),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
