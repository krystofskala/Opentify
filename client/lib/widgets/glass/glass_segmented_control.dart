import 'package:flutter/material.dart';

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
            child: Padding(
              padding: const EdgeInsets.all(3),
              // Mix: stopa sklo/plochá, vybraná kapsle expresivně tónová (M3).
              child: SelectedCapsule(color: theme.colorScheme.primaryContainer),
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
                              ? theme.colorScheme.onPrimaryContainer
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
                                        ? theme.colorScheme.onPrimaryContainer
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

/// Zarovnání posuvné kapsle pro `index` z `count` stejně širokých položek.
Alignment slideAlignment(int index, int count) =>
    Alignment(count <= 1 ? 0 : -1 + 2 * index / (count - 1), 0);

/// Vybraná kapsle v segmentech/tab baru: v obsahu (světlý režim) bílá
/// s drobným stínem jako iOS, jinak "stejný materiál + bílá navíc"
/// (`GlassTokens.emphasis`) s vlasovou hranou.
class SelectedCapsule extends StatelessWidget {
  const SelectedCapsule({super.key, this.color});

  /// `null` = neutrální skleněná kapsle (tab bar, navigace); jinak tónová
  /// barva (segmenty -- M3 Expressive vybraný stav).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shape = glassShape(const BorderRadius.all(Radius.circular(999)));
    final fill = color ??
        (isDark ? Colors.white.withValues(alpha: 0.14 + GlassTokens.emphasis) : Colors.white.withValues(alpha: 0.6));
    return AnimatedContainer(
      duration: Motion.state.duration,
      curve: Motion.state,
      decoration: ShapeDecoration(
        shape: shape,
        color: fill,
        shadows: const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: CustomPaint(
        painter: GlassEdgePainter(shape: shape),
        // Tónová pilulka (M3) dostane skleněný vnitřní lesk u horní hrany --
        // jediný recept "vybráno", kde se oba jazyky spojují (design audit).
        child: color == null
            ? const SizedBox.expand()
            : ClipPath(
                clipper: ShapeBorderClipper(shape: shape),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.5],
                      colors: [
                        Color.fromRGBO(255, 255, 255, Expressive.selectedPillHighlightAlpha),
                        Color.fromRGBO(255, 255, 255, 0),
                      ],
                    ),
                  ),
                  child: SizedBox.expand(),
                ),
              ),
      ),
    );
  }
}
