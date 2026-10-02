import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';

/// Jedno tlačítko řazení pro celou appku (Knihovna, album, playlist, Oblíbené)
/// -- kapsle "⇅ Aktuální řazení", výběr ve skleněném sheetu se zatržítkem
/// (audit UI: dřív dvě různá vyskakovací menu).
class SortButton<T> extends StatelessWidget {
  const SortButton({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;

  Future<void> _open(BuildContext context) async {
    HapticFeedback.selectionClick();
    final picked = await showGlassSheet<T>(
      context,
      builder: (sheet) => GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                child: Text('Řadit podle', style: Theme.of(sheet).textTheme.titleMedium),
              ),
              for (final entry in labels.entries)
                ListTile(
                  dense: true,
                  shape: AppShapes.md,
                  title: Text(entry.value),
                  trailing: entry.key == value
                      ? Icon(Symbols.check_rounded, color: Theme.of(sheet).colorScheme.primary)
                      : null,
                  onTap: () => Navigator.of(sheet).pop(entry.key),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != value) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) => ActionChip(
        tooltip: 'Řazení',
        avatar: const Icon(Symbols.sort_rounded, size: 18),
        label: Text(labels[value] ?? ''),
        onPressed: () => _open(context),
      );
}
