import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/library_repository.dart';
import '../models/recording_model.dart';
import '../state/provisioning_controller.dart';
import '../state/providers.dart';
import '../theme/design_tokens.dart';
import 'glass/glass.dart';

/// Zvyšuje se po každém odebrání z knihovny -- obrazovky Knihovny ho
/// sledují a přenačtou se (seznam skladeb drží vlastní stránkovaný stav).
String _plural(int n, String one, String few, String many) => n == 1 ? one : (n >= 2 && n <= 4 ? few : many);

final libraryRevisionProvider = StateProvider<int>((ref) => 0);

/// "Odebrat z knihovny" -- nejdřív náhled (co se smaže / jen skryje, kolik
/// místa se uvolní) v potvrzovacím sheetu, pak skutečné odebrání, snackbar a
/// obnovení Knihovny. Vrací `true`, když se něco odebralo.
Future<bool> confirmRemoveFromLibrary(BuildContext context, List<RecordingModel> tracks) async {
  if (tracks.isEmpty) return false;
  // Kontejner (ne WidgetRef) -- volá se i z kontextového menu, které se
  // před potvrzením zavře a jeho `ref` by už neplatil.
  final container = ProviderScope.containerOf(context, listen: false);
  final repo = container.read(libraryRepositoryProvider);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ids = tracks.map((r) => r.id).toList();

  LibraryRemovalResult preview;
  try {
    preview = await repo.removeTracks(ids, dryRun: true);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Nepodařilo se připravit odebrání: $e')));
    return false;
  }
  if (preview.removed == 0) {
    messenger?.showSnackBar(const SnackBar(content: Text('Nic z toho není v knihovně.')));
    return false;
  }
  if (!context.mounted) return false;

  final confirmed = await showGlassSheet<bool>(
    context,
    builder: (sheetContext) => _ConfirmRemoveSheet(tracks: tracks, preview: preview),
  );
  if (confirmed != true) return false;

  try {
    final result = await repo.removeTracks(ids);
    final parts = [
      '${result.removed == 1 ? 'Skladba' : '${result.removed} ${_plural(result.removed, 'skladba', 'skladby', 'skladeb')}'} ${_plural(result.removed, 'odebrána', 'odebrány', 'odebráno')} z knihovny',
      if (result.freedBytes > 0) 'uvolněno ${formatMegabytes(result.freedBytes)}',
    ];
    messenger?.showSnackBar(SnackBar(content: Text(parts.join(' · '))));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Odebrání selhalo: $e')));
    return false;
  }

  container.read(libraryRevisionProvider.notifier).state++;
  container.invalidate(likedSongsProvider);
  container.invalidate(homeProvider);
  final provisioning = container.read(provisioningControllerProvider.notifier);
  for (final id in ids) {
    provisioning.forget(id);
  }
  return true;
}

class _ConfirmRemoveSheet extends StatelessWidget {
  const _ConfirmRemoveSheet({required this.tracks, required this.preview});

  final List<RecordingModel> tracks;
  final LibraryRemovalResult preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final single = tracks.length == 1;
    final title =
        single ? 'Odebrat „${tracks.first.title}“ z knihovny?' : 'Odebrat ${preview.removed} ${_plural(preview.removed, 'skladbu', 'skladby', 'skladeb')} z knihovny?';
    final lines = <(IconData, String)>[
      if (preview.deleted > 0)
        (
          Symbols.delete_rounded,
          single
              ? 'Stažený soubor se smaže a uvolní ${formatMegabytes(preview.freedBytes)}.'
              : '${preview.deleted} ${_plural(preview.deleted, 'stažený soubor se smaže', 'stažené soubory se smažou', 'stažených souborů se smaže')} a uvolní ${formatMegabytes(preview.freedBytes)}.',
        ),
      if (preview.hidden > 0)
        (
          Symbols.visibility_off_rounded,
          single
              ? 'Je z tvé vlastní hudební složky – soubor zůstane, jen se skryje z knihovny.'
              : '${preview.hidden} ${_plural(preview.hidden, 'skladba z tvé vlastní složky se jen skryje, soubor zůstane', 'skladby z tvé vlastní složky se jen skryjí, soubory zůstanou', 'skladeb z tvé vlastní složky se jen skryje, soubory zůstanou')}.',
        ),
      (
        Symbols.info_rounded,
        'Oblíbené a playlisty zůstanou beze změny; skladba jde kdykoliv znovu přehrát a stáhnout.'
      ),
    ];
    return GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            for (final (icon, text) in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            GlassButton(
              label: preview.deleted > 0 ? 'Odebrat a smazat soubory' : 'Odebrat z knihovny',
              icon: Symbols.delete_rounded,
              destructive: true,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: AppSpacing.xs),
            GlassButton(
              label: 'Zrušit',
              style: GlassButtonStyle.plain,
              expand: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
  }
}
