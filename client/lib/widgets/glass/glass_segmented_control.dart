import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_tokens.dart';
import '../glass_container.dart';
import 'glass_button.dart';
import 'glass_pressable.dart';

class GlassSegment<T> {
  const GlassSegment({required this.value, required this.label, this.icon});

  final T value;

  /// Podstatné jméno, krátké (HIG: "Use nouns or noun phrases for segment
  /// labels"). U ikonových segmentů slouží jako popisek pro čtečky.
  final String label;

  /// Ikonový segment -- v jednom ovladači buď VŠECHNY s ikonou, nebo žádný
  /// (HIG: "Prefer using either text or images -- not a mix of both").
  final IconData? icon;
}

/// Segmentový ovladač s posuvnou vybranou kapslí. HIG Segmented controls
/// (https://developer.apple.com/design/human-interface-guidelines/segmented-controls):
/// - "no more than about five segments on iPhone",
/// - stejné šířky segmentů ("When all segments have equal width, a
///   segmented control feels balanced"),
/// - přepíná mezi příbuznými pohledy/filtry, ne akce.
/// V obsahu je stopa plochá (tertiary fill); `floating: true` = skleněná
/// stopa pro plovoucí vrstvu (lišta). Výška 36, dotyková plocha 44.
class GlassSegmentedControl<T> extends StatelessWidget {
  const GlassSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.floating = false,
  })  : assert(segments.length >= 2 && segments.length <= 5, 'HIG: 2–5 segmentů na iPhonu.'),
        width = null;

  /// Kompaktní ikonový přepínač (např. seznam/mřížka) -- pevná šířka.
  const GlassSegmentedControl.icons({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.floating = false,
    this.width = 96,
  }) : assert(segments.length >= 2 && segments.length <= 5);

  final double? width;

  final List<GlassSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    assert(segments.every((s) => s.icon == null) || segments.every((s) => s.icon != null),
        'HIG: nemíchat text a ikony v jednom segmentovém ovladači.');
    // V obsahu M3 Expressive "connected button group" -- skleněná posuvná
    // kapsle bez skutečného lomu světla (který Flutter web neumí) vypadala
    // jako levná napodobenina iOS (zpětná vazba uživatele). Sklo zůstává
    // jen pro plovoucí vrstvu (`floating`).
    if (!floating) return _ConnectedSegments<T>(segments: segments, selected: selected, onChanged: onChanged, width: width);
    return _buildGlass(context);
  }

  Widget _buildGlass(BuildContext context) {
    final theme = Theme.of(context);
    final index = segments.indexWhere((s) => s.value == selected).clamp(0, segments.length - 1);
    const height = GlassTokens.compactControlHeight;
    const radius = BorderRadius.all(Radius.circular(height / 2));

    final track = Stack(
      children: [
        AnimatedAlign(
          alignment: slideAlignment(index, segments.length),
          duration: Motion.enter.duration,
          curve: Motion.enter,
          child: FractionallySizedBox(
            widthFactor: 1 / segments.length,
            heightFactor: 1,
            // Tónovaná skleněná "čočka" (viz SelectedCapsule) -- barva
            // ze seedu jen jemně prosvítá sklem, žádná plná plastová pilulka.
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: SelectedCapsule(tint: theme.colorScheme.primary),
            ),
          ),
        ),
        Row(
          children: [
            for (final segment in segments)
              Expanded(
                child: GlassPressable(
                  onPressed: segment.value == selected ? () {} : () => onChanged(segment.value),
                  shape: const StadiumBorder(),
                  semanticLabel: segment.label,
                  selected: segment.value == selected,
                  highlightColor: Colors.transparent,
                  minSize: const Size(0, GlassTokens.minHitTarget),
                  child: SizedBox(
                    height: height,
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: GlassTokens.stateDuration,
                        style: theme.textTheme.labelLarge!.copyWith(
                          fontWeight: segment.value == selected ? FontWeight.w700 : FontWeight.w500,
                          color: segment.value == selected
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        child: segment.icon == null
                            ? Text(segment.label, maxLines: 1, overflow: TextOverflow.ellipsis)
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    segment.icon,
                                    size: 18,
                                    color: segment.value == selected
                                        ? theme.colorScheme.onSurface
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  // `.icons` = jen ikona (popisek pro čtečky),
                                  // jinak ikona + popisek -- u všech segmentů
                                  // stejně, nikdy mix.
                                  if (width == null) ...[
                                    const SizedBox(width: 6),
                                    Flexible(child: Text(segment.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  ],
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );

    return SizedBox(
      height: GlassTokens.minHitTarget,
      width: width,
      child: Center(
        child: SizedBox(
          height: height,
          child: floating
              ? GlassContainer(borderRadius: radius, child: track)
              : DecoratedBox(
                  decoration: ShapeDecoration(shape: glassShape(radius), color: tonalFill(context)),
                  child: track,
                ),
        ),
      ),
    );
  }
}

/// M3 Expressive spojená skupina tlačítek (connected button group,
/// https://m3.material.io/components/button-groups): samostatné tónové
/// dílky s 2 px mezerou, vnější rohy plně kulaté, vnitřní malé
/// (`Expressive.groupInnerCorner`). Vybraný dílek se pružinou "nafoukne"
/// do plné pilulky, dostane `secondaryContainer` a zatržítko; ostatní
/// `surfaceContainerHigh`. Stisk = pružinový morf rohů (GlassPressable).
class _ConnectedSegments<T> extends StatelessWidget {
  const _ConnectedSegments({required this.segments, required this.selected, required this.onChanged, this.width});

  final List<GlassSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final double? width;

  static const double _height = 40;
  static const double _gap = 2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconsOnly = width != null;
    final children = <Widget>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isSelected = segment.value == selected;
      const outer = Radius.circular(_height / 2);
      const inner = Radius.circular(Expressive.groupInnerCorner);
      final radius = isSelected
          ? const BorderRadius.all(outer)
          : BorderRadius.horizontal(
              left: i == 0 ? outer : inner,
              right: i == segments.length - 1 ? outer : inner,
            );
      final fg = isSelected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
      if (i > 0) children.add(const SizedBox(width: _gap));
      children.add(Expanded(
        child: GlassPressable(
          onPressed: isSelected ? () {} : () => onChanged(segment.value),
          shape: RoundedRectangleBorder(borderRadius: radius),
          semanticLabel: segment.label,
          selected: isSelected,
          highlightColor: Colors.transparent,
          minSize: const Size(0, GlassTokens.minHitTarget),
          child: AnimatedContainer(
            duration: Motion.enter.duration,
            curve: Motion.enter,
            height: _height,
            decoration: ShapeDecoration(
              shape: RoundedRectangleBorder(borderRadius: radius),
              color: isSelected ? scheme.secondaryContainer : scheme.surfaceContainerHigh.withValues(alpha: 0.82),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: Motion.enter.duration,
                    curve: Motion.enter,
                    child: isSelected && !iconsOnly
                        ? Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(Symbols.check_rounded, size: 18, color: fg),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (segment.icon != null) ...[
                    Icon(segment.icon, size: 18, color: fg, fill: isSelected ? 1 : 0),
                    if (!iconsOnly) const SizedBox(width: 6),
                  ],
                  if (!iconsOnly)
                    Flexible(
                      child: AnimatedDefaultTextStyle(
                        duration: GlassTokens.stateDuration,
                        style: Theme.of(context).textTheme.labelLarge!.copyWith(
                              color: fg,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                            ),
                        child: Text(segment.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
    }
    return SizedBox(
      width: width,
      height: GlassTokens.minHitTarget,
      child: Center(child: SizedBox(height: _height, child: Row(children: children))),
    );
  }
}

/// Zarovnání posuvné kapsle pro `index` z `count` stejně širokých položek.
Alignment slideAlignment(int index, int count) =>
    Alignment(count <= 1 ? 0 : -1 + 2 * index / (count - 1), 0);

/// Vybraná kapsle v segmentech/tab baru -- "čočka" z tónovaného skla po
/// vzoru iOS 26: převážně průhledná (pod ní dál prosvítá stopa), jemně
/// tónovaná barvou ze seedu, s ostrou světelnou hranou (nahoře jasná,
/// dole téměř neviditelná), tenkou tmavší linkou u spodní hrany a
/// měkkým dvojitým stínem, který ji "zvedne" nad stopu. Žádný plastový
/// lesklý pruh přes polovinu výšky -- to působilo levně.
class SelectedCapsule extends StatelessWidget {
  const SelectedCapsule({super.key, this.tint});

  /// `null` = neutrální sklo (tab bar); jinak barva, kterou se sklo jemně
  /// tónuje (segmenty).
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shape = glassShape(const BorderRadius.all(Radius.circular(999)));
    final base = isDark ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.62);
    final fill = tint == null ? base : Color.alphaBlend(tint!.withValues(alpha: isDark ? 0.24 : 0.14), base);
    return AnimatedContainer(
      duration: Motion.state.duration,
      curve: Motion.state,
      decoration: ShapeDecoration(
        shape: shape,
        color: fill,
        shadows: [
          BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.10), blurRadius: 14, offset: const Offset(0, 4)),
          BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.06), blurRadius: 2, offset: const Offset(0, 1)),
        ],
      ),
      child: CustomPaint(
        foregroundPainter: _LensRimPainter(shape: shape, isDark: isDark),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Světelná hrana skleněné čočky: gradientní obrys (nahoře jasný, dole
/// slábne) + velmi jemný vnitřní odlesk jen u horní hrany.
class _LensRimPainter extends CustomPainter {
  const _LensRimPainter({required this.shape, required this.isDark});

  final ShapeBorder shape;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outline = shape.getOuterPath(rect.deflate(0.5));
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.55 : 0.9),
            Colors.white.withValues(alpha: isDark ? 0.10 : 0.35),
            Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipPath(shape.getOuterPath(rect));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.4),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: isDark ? 0.10 : 0.35), Colors.white.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.4)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LensRimPainter old) => old.isDark != isDark || old.shape != shape;
}
