import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/audio_player_controller.dart';
import '../state/auth_controller.dart' show deviceName;
import '../state/connect_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import '../state/providers.dart' show realtimeClientProvider;

IconData _deviceIcon(String name) => name.startsWith('iPhone') || name.startsWith('Android')
    ? Symbols.smartphone_rounded
    : name.contains('prohlížeč')
        ? Symbols.computer_rounded
        : Symbols.devices_rounded;

/// Opentify Connect: zařízení profilu, co na nich hraje, ovládání na dálku
/// a "Přehrát tady" / "Pustit tam".
Future<void> showConnectSheet(BuildContext context) {
  HapticFeedback.selectionClick();
  return showGlassSheet<void>(context, builder: (_) => const _ConnectSheet());
}

class _ConnectSheet extends ConsumerWidget {
  const _ConnectSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final devices = ref.watch(connectProvider);
    // Jen co hraje a jestli hraje -- ne pozice (překreslovalo se ~5x za vteřinu).
    final local = ref.watch(
        audioPlayerControllerProvider.select((s) => (nowPlaying: s.nowPlaying, isPlaying: s.isPlaying)));
    final connect = ref.read(connectProvider.notifier);
    final localPlaying = local.nowPlaying != null;

    return GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text('Zařízení', style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 2, AppSpacing.md, 0),
              child: Builder(builder: (context) {
                final online = ref.read(realtimeClientProvider).isConnected;
                return Row(
                  children: [
                    Icon(online ? Symbols.wifi_rounded : Symbols.wifi_off_rounded,
                        size: 14, color: online ? theme.colorScheme.primary : theme.colorScheme.error),
                    const SizedBox(width: 4),
                    Text(
                      online ? 'Spojeno se serverem' : 'Bez spojení – zkouším znovu…',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                );
              }),
            ),
            const SizedBox(height: AppSpacing.xs),
            ListTile(
              shape: AppShapes.md,
              leading: Icon(_deviceIcon(deviceName()), color: theme.colorScheme.primary),
              title: Text('Toto zařízení', style: TextStyle(color: theme.colorScheme.primary)),
              subtitle: Text(local.nowPlaying == null
                  ? deviceName()
                  : '${local.isPlaying ? 'Hraje' : 'Pozastaveno'}: ${local.nowPlaying!.title}'),
            ),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  'Žádné další zařízení. Otevři Opentify na mobilu nebo v prohlížeči se stejným profilem '
                  'a objeví se tady – můžeš pak ovládat, co tam hraje, nebo přehrávání převzít.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            for (final d in devices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      shape: AppShapes.md,
                      leading: Icon(_deviceIcon(d.name)),
                      title: Text(d.name),
                      subtitle: Text(
                        d.hasTrack
                            ? '${d.isPlaying ? 'Hraje' : 'Pozastaveno'}: ${d.title}${d.artist != null ? ' · ${d.artist}' : ''}'
                            : 'Nic nehraje',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: d.hasTrack
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: d.isPlaying ? 'Pozastavit' : 'Přehrát',
                                  icon: Icon(d.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                                  onPressed: () => connect.command(d.id, 'toggle'),
                                ),
                                IconButton(
                                  tooltip: 'Další',
                                  icon: const Icon(Symbols.skip_next_rounded),
                                  onPressed: () => connect.command(d.id, 'next'),
                                ),
                              ],
                            )
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      child: Wrap(
                        spacing: AppSpacing.xs,
                        children: [
                          if (d.hasTrack)
                            GlassButton(
                              label: 'Přehrát tady',
                              icon: Symbols.phonelink_rounded,
                              style: GlassButtonStyle.tonal,
                              compact: true,
                              onPressed: () {
                                connect.takeOver(d.id);
                                Navigator.of(context).pop();
                              },
                            ),
                          if (localPlaying)
                            GlassButton(
                              label: 'Pustit tam',
                              icon: Symbols.cast_rounded,
                              style: GlassButtonStyle.plain,
                              compact: true,
                              onPressed: () {
                                connect.sendTo(d.id);
                                Navigator.of(context).pop();
                              },
                            ),
                        ],
                      ),
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

/// Lišta "Hraje na <zařízení>" -- tady nic nehraje, jinde ano (jako zelená
/// lišta Spotify Connect). Ovládání na dálku a převzetí jedním klepnutím.
class RemotePlayingBar extends ConsumerWidget {
  const RemotePlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(remotePlayingProvider);
    if (d == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final connect = ref.read(connectProvider.notifier);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        GlassTokens.floatingMargin,
        0,
        GlassTokens.floatingMargin,
        8 + MediaQuery.paddingOf(context).bottom,
      ),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(GlassTokens.tabBarHeight / 2),
        rim: true,
        liquid: true,
        child: InkWell(
          onTap: () => showConnectSheet(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox.square(
                    dimension: 44,
                    child: ArtworkImage(url: d.artworkUrl, icon: Symbols.music_note_rounded),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                      Row(
                        children: [
                          Icon(_deviceIcon(d.name), size: 14, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Hraje na: ${d.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: d.isPlaying ? 'Pozastavit tam' : 'Přehrát tam',
                  icon: Icon(d.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                  onPressed: () => connect.command(d.id, 'toggle'),
                ),
                GlassButton(
                  label: 'Převzít',
                  style: GlassButtonStyle.tonal,
                  compact: true,
                  onPressed: () => connect.takeOver(d.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
