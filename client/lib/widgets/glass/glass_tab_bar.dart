import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_tokens.dart';
import '../glass_container.dart';
import 'glass_pressable.dart';
import 'glass_segmented_control.dart';

class GlassTabItem {
  const GlassTabItem({required this.icon, required this.label});

  /// Obrysová varianta; vybraný tab se kreslí vyplněně (HIG Tab bars:
  /// "Prefer filled symbols" -- vyplněná = vybraná, obrys = ostatní).
  final IconData icon;

  /// Jedno slovo (HIG: "Use single words whenever possible").
  final String label;
}

/// Plovoucí skleněný tab bar (kapsle) s posuvnou zvýrazněnou kapslí.
/// HIG Tab bars (https://developer.apple.com/design/human-interface-guidelines/tab-bars):
/// "A tab bar floats above content at the bottom of the screen. Its items
/// rest on a Liquid Glass background that allows content beneath to peek
/// through." Jen navigace, žádné akce; popisky vždy; barva popisků
/// `onSurface` (ne akcent -- "Avoid applying a similar color to tab labels
/// and content layer backgrounds").
/// Rozměry: `GlassTokens.tabBarHeight`, okraje `floatingMargin`, mezera
/// nad safe area `floatingBottomGap`.
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({super.key, required this.items, required this.selectedIndex, required this.onSelected});

  final List<GlassTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 12 px NAD skutečným spodním insetem (home indikátor iPhonu).
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset + GlassTokens.floatingBottomGap),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: GlassTokens.floatingMargin),
        child: GlassContainer(
          borderRadius: const BorderRadius.all(Radius.circular(GlassTokens.tabBarHeight / 2)),
          shadow: true,
          lens: true,
          child: SizedBox(
            height: GlassTokens.tabBarHeight,
            child: Stack(
              children: [
                AnimatedAlign(
                  alignment: slideAlignment(selectedIndex, items.length),
                  duration: Expressive.spatialDefault.duration,
                  curve: Expressive.spatialDefault,
                  child: FractionallySizedBox(
                    widthFactor: 1 / items.length,
                    heightFactor: 1,
                    child: const Padding(padding: EdgeInsets.all(5), child: SelectedCapsule()),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      Expanded(
                        child: GlassPressable(
                          onPressed: () => onSelected(i),
                          shape: const StadiumBorder(),
                          semanticLabel: items[i].label,
                          selected: i == selectedIndex,
                          highlightColor: Colors.transparent,
                          minSize: const Size(0, GlassTokens.minHitTarget),
                          child: SizedBox(
                            height: GlassTokens.tabBarHeight,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                i == selectedIndex
                                    ? VariedIcon.varied(items[i].icon, fill: 1, size: 24, color: theme.colorScheme.onSurface)
                                    : Icon(items[i].icon, size: 24, color: theme.colorScheme.onSurfaceVariant),
                                const SizedBox(height: 2),
                                Text(
                                  items[i].label,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 11,
                                    fontWeight: i == selectedIndex ? FontWeight.w700 : FontWeight.w500,
                                    color: i == selectedIndex
                                        ? theme.colorScheme.onSurface
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
