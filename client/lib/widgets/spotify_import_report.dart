import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/library_repository.dart';
import '../theme/design_tokens.dart';
import 'state_views.dart';
import '../theme/glass_tokens.dart';
import '../core/cz_plural.dart';
import 'glass/glass.dart';

/// Souhrn po importu Spotify exportu -- po playlistech: kolik skladeb,
/// kolik jde přehrát hned (`inLibrary`), kolik se přeskočilo (epizody
/// podcastů, položky bez interpreta/názvu). Klik otevře playlist.
Future<void> showSpotifyImportReport(BuildContext context, SpotifyImportResult result) {
  return showGlassSheet<void>(
    context,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scrollController) => GlassContainer(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
        shadow: false,
        fit: StackFit.expand,
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: _ImportReport(result: result, scrollController: scrollController),
      ),
    ),
  );
}

class _ImportReport extends StatelessWidget {
  const _ImportReport({required this.result, required this.scrollController});

  final SpotifyImportResult result;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playable = result.playlists.fold<int>(0, (sum, p) => sum + p.inLibrary);
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Import ze Spotify hotový', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  _Stat(icon: Symbols.queue_music_rounded, label: playlistsCount(result.playlistsImported)),
                  _Stat(icon: Symbols.music_note_rounded, label: songsCount(result.matched)),
                  _Stat(icon: Symbols.play_circle_rounded, label: '$playable hned k přehrání'),
                  if (result.skipped > 0) _Stat(icon: Symbols.block_rounded, label: '${result.skipped} přeskočeno'),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Skladby, které ještě nejsou v knihovně, se stáhnou při prvním přehrání. '
                'Opakovaný import playlisty aktualizuje, nezdvojí je.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SectionHeader('Playlisty'),
        for (final p in result.playlists)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.secondaryContainer,
              foregroundColor: theme.colorScheme.onSecondaryContainer,
              child: const Icon(Symbols.queue_music_rounded, size: 20),
            ),
            title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                (songsCount(p.matched)),
                '${p.inLibrary} v knihovně',
                if (p.skipped > 0) '${p.skipped} přeskočeno',
              ].join(' · '),
            ),
            trailing: const Icon(Symbols.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/playlists/${p.id}');
            },
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Chip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        visualDensity: VisualDensity.compact,
      );
}
