import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/player_buttons_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';

/// Výběr tlačítek spodní řady přehrávače: zaškrtnout až 5, pořadí = pořadí
/// zaškrtnutí (číslo u položky).
Future<void> showPlayerButtonsSheet(BuildContext context) =>
    showGlassSheet<void>(context, builder: (_) => const _PlayerButtonsSheet());

class _PlayerButtonsSheet extends ConsumerStatefulWidget {
  const _PlayerButtonsSheet();

  @override
  ConsumerState<_PlayerButtonsSheet> createState() => _PlayerButtonsSheetState();
}

class _PlayerButtonsSheetState extends ConsumerState<_PlayerButtonsSheet> {
  late List<PlayerButton> _picked = [...ref.read(playerButtonsProvider)];

  void _toggle(PlayerButton b) {
    setState(() {
      if (_picked.contains(b)) {
        _picked.remove(b);
      } else if (_picked.length < maxPlayerButtons) {
        _picked.add(b);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text('Tlačítka přehrávače', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 2, AppSpacing.md, AppSpacing.xs),
              child: Text(
                'Vyber až $maxPlayerButtons. Pořadí je podle toho, jak je zaškrtneš.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            for (final b in PlayerButton.values)
              ListTile(
                dense: true,
                shape: AppShapes.md,
                leading: Icon(b.icon),
                title: Text(b.label),
                enabled: _picked.contains(b) || _picked.length < maxPlayerButtons,
                trailing: _picked.contains(b)
                    ? CircleAvatar(
                        radius: 12,
                        backgroundColor: theme.colorScheme.primary,
                        child: Text('${_picked.indexOf(b) + 1}',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onPrimary)),
                      )
                    : null,
                onTap: () => _toggle(b),
              ),
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  GlassButton(
                    label: 'Výchozí',
                    icon: Symbols.restart_alt_rounded,
                    style: GlassButtonStyle.plain,
                    onPressed: () => setState(() => _picked = [...defaultPlayerButtons]),
                  ),
                  const Spacer(),
                  GlassButton(
                    label: 'Uložit',
                    style: GlassButtonStyle.prominent,
                    onPressed: _picked.isEmpty
                        ? null
                        : () {
                            ref.read(playerButtonsProvider.notifier).set(_picked);
                            Navigator.of(context).pop();
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
