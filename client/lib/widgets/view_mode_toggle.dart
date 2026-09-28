import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

enum ViewMode { list, grid }

/// Přepínač seznam/karty -- dřív existoval jen jako `_SongsViewMode`
/// inline v Library's Songs tabu; teď sdílený, aby ho šlo dát i na
/// Albums/Artists taby (které byly natvrdo jen mřížkové).
class ViewModeToggle extends StatelessWidget {
  const ViewModeToggle({super.key, required this.mode, required this.onChanged});

  final ViewMode mode;
  final ValueChanged<ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ViewMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: ViewMode.list, icon: Icon(Symbols.view_list_rounded), tooltip: 'Seznam'),
        ButtonSegment(value: ViewMode.grid, icon: Icon(Symbols.grid_view_rounded), tooltip: 'Karty'),
      ],
      selected: {mode},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
