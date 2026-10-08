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
  const OfflineTab({super.key, this.episodes = false});

  /// Režim mluveného slova: jen epizody podcastů (`pc:`); v hudbě jen skladby.
  final bool episodes;

  Future<void> _clearAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(episodes ? 'Smazat offline epizody?' : 'Smazat offline skladby?'),
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
    if (ok != true) return;
    final ctrl = ref.read(offlineControllerProvider.notifier);
    // Jen to, co je v tomhle režimu vidět (skladby / epizody).
    final ids = ref.read(offlineControllerProvider).tracks.keys.where((id) => _spoken(id) == episodes).toList();
    for (final id in ids) {
      await ctrl.remove(id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final offline = ref.watch(offlineControllerProvider);
    final tracks = offline.tracks.values.where((t) => _spoken(t.id) == episodes).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (episodes) _orderBooks(tracks);
    final pendingCount = offline.pending.keys.where((id) => _spoken(id) == episodes).length;
    String count(int n) => episodes ? '$n ${n == 1 ? 'položka' : (n < 5 && n > 0 ? 'položky' : 'položek')}' : songsCount(n);
    final usage = ref.watch(offlineUsageProvider).valueOrNull;
    final ownBytes = tracks.fold<int>(0, (a, t) => a + t.bytes);

    if (tracks.isEmpty && pendingCount == 0) {
      return EmptyState(
        icon: Symbols.download_for_offline_rounded,
        message: episodes
            ? 'Epizody a audioknihy stažené do zařízení hrají i bez internetu. Epizodu stáhneš u epizody, '
                'knihu v jejím menu (podržení) – „Stáhnout do zařízení“.'
            : 'Skladby stažené do zařízení hrají i bez internetu. '
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
                  Text('${count(tracks.length)} · ${formatBytes(ownBytes)}', style: theme.textTheme.titleMedium),
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
        if (pendingCount > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: muted)),
              const SizedBox(width: AppSpacing.sm),
              Text('Stahuje se ${count(pendingCount)}…', style: theme.textTheme.bodyMedium),
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
            onTap: () {
              // Díl knihy: jen díly téže knihy, v pořadí (ne všechno stažené).
              final group = _groupOf(tracks[i].id);
              if (group == null) {
                ref.read(audioPlayerControllerProvider.notifier).playQueue(infos, i, sourceLabel: 'Offline');
                return;
              }
              final idx = [for (var k = 0; k < tracks.length; k++) if (_groupOf(tracks[k].id) == group) k];
              ref.read(audioPlayerControllerProvider.notifier).playQueue(
                    [for (final k in idx) infos[k]],
                    idx.indexOf(i),
                    sourceLabel: tracks[i].artist ?? 'Offline',
                    shuffle: false,
                  );
            },
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
              icon: const Icon(Symbols.delete_rounded, semanticLabel: 'Smazat ze zařízení'),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// Mluvené slovo v zařízení: epizody podcastů i díly audioknih (do hudby
/// nepatří -- dřív by se díly knih ukázaly mezi skladbami).
bool _spoken(String id) => id.startsWith('pc:') || id.startsWith('sp:');

/// Kniha dílu (`sp:<kniha>:<soubor>`), jinak null.
String? _groupOf(String id) {
  if (!id.startsWith('sp:')) return null;
  final parts = id.split(':');
  return parts.length >= 3 ? parts[1] : null;
}

/// Knihy pohromadě a jejich díly v pořadí zařazení (díl 1 napřed); knihy a
/// epizody podle toho, co je nejnovější.
void _orderBooks(List<OfflineTrack> tracks) {
  final newest = <String, DateTime>{};
  for (final t in tracks) {
    final key = _groupOf(t.id) ?? t.id;
    final at = newest[key];
    if (at == null || t.addedAt.isAfter(at)) newest[key] = t.addedAt;
  }
  tracks.sort((a, b) {
    final ga = _groupOf(a.id) ?? a.id, gb = _groupOf(b.id) ?? b.id;
    if (ga != gb) return newest[gb]!.compareTo(newest[ga]!);
    return a.addedAt.compareTo(b.addedAt);
  });
}
