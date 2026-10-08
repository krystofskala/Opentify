import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'glass/glass.dart';

enum ViewMode { list, grid }

/// Přepínač seznam / karty (Skladby, Alba, Interpreti).
class ViewModeToggle extends StatelessWidget {
  const ViewModeToggle({super.key, required this.mode, required this.onChanged});

  final ViewMode mode;
  final ValueChanged<ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return GlassSegmentedControl<ViewMode>.icons(
      segments: const [
        GlassSegment(value: ViewMode.list, label: 'Seznam', icon: Symbols.view_list_rounded),
        GlassSegment(value: ViewMode.grid, label: 'Karty', icon: Symbols.grid_view_rounded),
      ],
      selected: mode,
      onChanged: onChanged,
    );
  }
}
