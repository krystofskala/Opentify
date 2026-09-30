import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../glass_container.dart';
import 'glass_pressable.dart';

/// Styly tlačítek -- prominence dle HIG Buttons
/// (https://developer.apple.com/design/human-interface-guidelines/buttons),
/// barvy a tvary dle M3 Expressive (tónové kontejnery ze seedu):
/// - [prominent] -- hlavní akce, plná `primary` kapsle. Max. 1–2 na
///   obrazovku ("Keep the number of prominent buttons to one or two per view").
/// - [tonal] -- vedlejší akce v OBSAHU: tónový `secondaryContainer` (M3),
///   žádné sklo (HIG Materials: "Don't use Liquid Glass in the content layer").
/// - [glass] -- vedlejší akce na PLOVOUCÍ vrstvě (přehrávač, lišty) -- sklo.
/// - [plain] -- jen text/ikona v barvě `primary`, bez pozadí.
/// Stisk: zmenšení + M3 morfologie (kapsle zmáčkne rohy,
/// `Expressive.pressedCornerFraction`) na pružině `Expressive.spatialFast`.
/// Stejná výška pro sadu voleb -- rozlišení stylem, ne velikostí ("Use style
/// -- not size -- to visually distinguish the preferred choice").
/// Destruktivní akce: `destructive: true`, nikdy `prominent` ("Don't assign
/// the primary role to a button that performs a destructive action").
enum GlassButtonStyle { prominent, tonal, glass, plain }

class _ButtonColors {
  const _ButtonColors(this.background, this.foreground);
  final Color? background;
  final Color foreground;
}

_ButtonColors _colorsFor(BuildContext context, GlassButtonStyle style, bool destructive) {
  final scheme = Theme.of(context).colorScheme;
  if (destructive) {
    return switch (style) {
      GlassButtonStyle.plain => _ButtonColors(null, scheme.error),
      _ => _ButtonColors(scheme.errorContainer, scheme.onErrorContainer),
    };
  }
  return switch (style) {
    GlassButtonStyle.prominent => _ButtonColors(scheme.primary, scheme.onPrimary),
    GlassButtonStyle.tonal => _ButtonColors(scheme.secondaryContainer, scheme.onSecondaryContainer),
    GlassButtonStyle.glass => _ButtonColors(null, scheme.onSurface),
    GlassButtonStyle.plain => _ButtonColors(null, scheme.primary),
  };
}

/// Kapslové tlačítko s textem (a volitelnou ikonou). Výška 44 (36
/// compact), dotyková plocha min. `GlassTokens.minHitTarget`.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = GlassButtonStyle.tonal,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.groupPosition,
    this.onLongPress,
  }) : assert(!(destructive && style == GlassButtonStyle.prominent), 'Destruktivní akce nesmí být prominent (HIG).');

  final String label;
  final VoidCallback? onPressed;

  /// Dlouhý stisk (např. "Přehrát" -> přehrát jako další / do fronty).
  final VoidCallback? onLongPress;
  final IconData? icon;
  final GlassButtonStyle style;
  final bool destructive;
  final bool compact;

  /// Roztáhnout na celou šířku (svislé stohy).
  final bool expand;

  /// Pozice ve spojené skupině (`GlassButtonGroup`) -- vnitřní rohy malé.
  final GroupPosition? groupPosition;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _colorsFor(context, style, destructive);
    final height = compact ? GlassTokens.compactControlHeight : GlassTokens.controlHeight;

    final labelRow = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: compact ? 18 : 20, color: colors.foreground), const SizedBox(width: 6)],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(color: colors.foreground, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
    final padding = EdgeInsets.symmetric(horizontal: compact ? 14 : 18);

    return GlassPressable(
      onPressed: onPressed,
      onLongPress: onPressed == null ? null : onLongPress,
      shape: glassShape(_radius(height, false, groupPosition)),
      semanticLabel: label,
      builder: (context, pressed) {
        final radius = _radius(height, pressed, groupPosition);
        final content = Padding(padding: padding, child: SizedBox(height: height, child: labelRow));
        final Widget body = style == GlassButtonStyle.glass
            ? GlassContainer(borderRadius: radius, child: content)
            : _MorphingSurface(radius: radius, color: colors.background, child: content);
        return expand ? SizedBox(width: double.infinity, child: body) : body;
      },
    );
  }
}

enum GroupPosition { first, middle, last }

/// Rohy kapsle: plné, při stisku zmáčknuté (M3 morf); ve skupině vnitřní
/// rohy `Expressive.groupInnerCorner`.
BorderRadius _radius(double height, bool pressed, GroupPosition? position) {
  final full = pressed ? height * Expressive.pressedCornerFraction : height / 2;
  final inner = pressed ? Expressive.cornerExtraSmall : Expressive.groupInnerCorner;
  final r = Radius.circular(full);
  final i = Radius.circular(inner);
  return switch (position) {
    null => BorderRadius.all(r),
    GroupPosition.first => BorderRadius.horizontal(left: r, right: i),
    GroupPosition.middle => BorderRadius.all(i),
    GroupPosition.last => BorderRadius.horizontal(left: i, right: r),
  };
}

/// Plocha tlačítka, jejíž rohy se animují pružinou (tvarový morf).
class _MorphingSurface extends StatelessWidget {
  const _MorphingSurface({required this.radius, required this.color, required this.child});

  final BorderRadius radius;
  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (color == null) return child;
    return TweenAnimationBuilder<BorderRadius?>(
      tween: BorderRadiusTween(end: radius),
      duration: Motion.press.duration,
      curve: Motion.press,
      builder: (context, value, child) => AnimatedContainer(
        duration: Motion.state.duration,
        curve: Motion.state,
        decoration: ShapeDecoration(shape: glassShape(value ?? radius), color: color),
        child: child,
      ),
      child: child,
    );
  }
}

/// Spojená skupina tlačítek (M3 Expressive "connected button group"):
/// sousední tlačítka sdílí malé vnitřní rohy, vnější jsou plné kapsle,
/// mezera 2 dp. Pro 2–3 příbuzné akce (Přehrát / Zamíchat).
class GlassButtonGroup extends StatelessWidget {
  const GlassButtonGroup({super.key, required this.buttons});

  /// Tlačítka BEZ `groupPosition` -- skupina ho doplní sama.
  final List<GlassButton> buttons;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          GlassButton(
            label: buttons[i].label,
            onPressed: buttons[i].onPressed,
            icon: buttons[i].icon,
            style: buttons[i].style,
            destructive: buttons[i].destructive,
            compact: buttons[i].compact,
            groupPosition: buttons.length == 1
                ? null
                : i == 0
                    ? GroupPosition.first
                    : i == buttons.length - 1
                        ? GroupPosition.last
                        : GroupPosition.middle,
          ),
        ],
      ],
    );
  }
}

/// Plochá výplň stopy/pole v obsahu -- tónová (M3), ne šedá: světle
/// tónovaný `surfaceContainerHighest` ze seedu.
Color tonalFill(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return scheme.surfaceContainerHighest.withValues(alpha: 0.85);
}

/// Kruhové tlačítko jen s ikonou (min. 44, dotyk 48). HIG Buttons:
/// "Circle -- Icon-only buttons". `tooltip` je povinný kvůli čtečkám.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.style = GlassButtonStyle.glass,
    this.size = 44,
    this.iconSize = 22,
    this.color,
    this.selected,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final GlassButtonStyle style;
  final double size;
  final double iconSize;
  final Color? color;

  /// Ikonové toggle tlačítko (mimo seznam, HIG Toggles) -- vybrané má
  /// tónovou výplň, nevybrané jen ikonu.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveStyle = selected == null
        ? style
        : (selected! ? GlassButtonStyle.prominent : GlassButtonStyle.tonal);
    final colors = _colorsFor(context, effectiveStyle, false);
    final foreground = color ?? (effectiveStyle == GlassButtonStyle.plain ? scheme.onSurface : colors.foreground);
    return GlassPressable(
      onPressed: onPressed,
      shape: const CircleBorder(),
      tooltip: tooltip,
      semanticLabel: tooltip,
      selected: selected,
      builder: (context, pressed) {
        final radius = BorderRadius.circular(pressed ? size * Expressive.pressedCornerFraction : size / 2);
        final iconWidget = SizedBox(width: size, height: size, child: Icon(icon, size: iconSize, color: foreground));
        return switch (effectiveStyle) {
          GlassButtonStyle.glass => GlassContainer(borderRadius: BorderRadius.circular(size / 2), child: iconWidget),
          GlassButtonStyle.plain => iconWidget,
          _ => _MorphingSurface(radius: radius, color: colors.background, child: iconWidget),
        };
      },
    );
  }
}

/// Tlačítko chovající se jako přepínač MIMO seznam. HIG Toggles: "Use the
/// switch toggle style only in a list row" -- jinde toggle-tlačítko; stav
/// zřejmý nejen barvou ("Avoid relying solely on different colors") --
/// zapnuté má tónovou výplň A ikonu zaškrtnutí.
class GlassToggleButton extends StatelessWidget {
  const GlassToggleButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.icon,
    this.compact = true,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height = compact ? GlassTokens.compactControlHeight : GlassTokens.controlHeight;
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return GlassPressable(
      onPressed: onChanged == null ? null : () => onChanged!(!selected),
      shape: glassShape(BorderRadius.circular(height / 2)),
      semanticLabel: label,
      selected: selected,
      builder: (context, pressed) => _MorphingSurface(
        radius: _radius(height, pressed, null),
        color: selected ? scheme.primaryContainer : tonalFill(context),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(selected ? Icons.check_rounded : (icon ?? Icons.add_rounded), size: 18, color: foreground),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.labelLarge?.copyWith(color: foreground, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sada tlačítek v řádku -- rozestup dle HIG Accessibility ("about 12
/// points of padding around elements that include a bezel").
class GlassButtonRow extends StatelessWidget {
  const GlassButtonRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, crossAxisAlignment: WrapCrossAlignment.center, children: children);
  }
}
