import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/cz_plural.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/artwork_provider.dart';
import '../../state/audio_player_controller.dart';
import '../../state/offline_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/net_image.dart';
import '../../widgets/state_views.dart';

/// "1,2 GB", "340 MB".
String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1).replaceAll('.', ',')} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).round()} MB';
  return '${(bytes / 1024).round()} kB';
}

/// Knihovna › Offline: skladby uložené v TOMHLE zařízení (hrají i bez
/// internetu) a kolik místa zabírají.
class OfflineTab extends ConsumerWidget {
  const OfflineTab({super.key});

  Future<void> _clearAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Smazat offline skladby?'),
        content: const Text('Smažou se jen z tohohle zařízení, v knihovně a na serveru zůstanou.'),
        actions: [
          GlassButton(
            label: 'Zrušit',
            style: GlassButtonStyle.plain,
            compact: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          GlassButton(label: 'Smazat', destructive: true, compact: true, onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (ok == true) await ref.read(offlineControllerProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final offline = ref.watch(offlineControllerProvider);
    final tracks = offline.tracks.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final usage = ref.watch(offlineUsageProvider).valueOrNull;
    final ownBytes = tracks.fold<int>(0, (a, t) => a + t.bytes);

    if (tracks.isEmpty && offline.pending.isEmpty) {
      return const EmptyState(
        icon: Symbols.download_for_offline_rounded,
        message: 'Skladby stažené do zařízení hrají i bez internetu. '
            'Stáhneš je v menu skladby, alba nebo playlistu – „Stáhnout do zařízení“.',
      );
    }

    final infos = [
      for (final t in tracks)
        NowPlayingInfo(
          recordingId: t.id,
          title: t.title,
          artistName: t.artist,
          artistId: t.artistId,
          releaseId: t.releaseId,
          artworkUrl: t.artworkUrl,
        ),
    ];

    return ListView(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 32 + navBottomInset(context)),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${songsCount(tracks.length)} · ${formatBytes(ownBytes)}', style: theme.textTheme.titleMedium),
                  Text(
                    usage?.quota != null && usage!.quota! > 0
                        ? 'v tomhle zařízení (volné pro appku ${formatBytes(usage.quota! - usage.usage)})'
                        : 'v tomhle zařízení',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            if (tracks.isNotEmpty)
              GlassButton(
                label: 'Smazat vše',
                icon: Symbols.delete_rounded,
                compact: true,
                onPressed: () => _clearAll(context, ref),
              ),
          ],
        ),
        if (offline.pending.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: muted)),
              const SizedBox(width: AppSpacing.sm),
              Text('Stahuje se ${songsCount(offline.pending.length)}…', style: theme.textTheme.bodyMedium),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        if (tracks.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              label: 'Přehrát',
              icon: Symbols.play_arrow_rounded,
              style: GlassButtonStyle.prominent,
              compact: true,
              onPressed: () =>
                  ref.read(audioPlayerControllerProvider.notifier).playQueue(infos, 0, sourceLabel: 'Offline'),
            ),
          ),
        const SizedBox(height: AppSpacing.xs),
        for (var i = 0; i < tracks.length; i++)
          _OfflineRow(
            track: tracks[i],
            onTap: () => ref.read(audioPlayerControllerProvider.notifier).playQueue(infos, i, sourceLabel: 'Offline'),
            onRemove: () => ref.read(offlineControllerProvider.notifier).remove(tracks[i].id),
          ),
      ],
    );
  }
}

class _OfflineRow extends ConsumerWidget {
  const _OfflineRow({required this.track, required this.onTap, required this.onRemove});

  final OfflineTrack track;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final art = track.artworkUrl ??
        ref.watch(recordingArtworkProvider((releaseId: track.releaseId, artistId: track.artistId))).valueOrNull;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: SizedBox.square(
                dimension: 48,
                child: art != null
                    ? NetImage(url: art)
                    : ColoredBox(color: theme.colorScheme.surfaceContainerHigh),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
                  Text(
                    '${track.artist ?? ''} · ${formatBytes(track.bytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Smazat ze zařízení',
              icon: const Icon(Symbols.remove_circle_outline_rounded),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
