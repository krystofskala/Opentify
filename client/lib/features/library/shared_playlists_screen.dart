import '../../routing/branches.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/collection_actions.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/playlist_card.dart' show PlaylistArtwork;
import '../../widgets/section_app_bar.dart';
import '../../widgets/spotify_link_import.dart';
import '../../widgets/state_views.dart';
import '../../core/cz_plural.dart';
import 'pinned_tile.dart';
import '../../widgets/playlist_removal.dart';

String _playlists(int n) => n == 1
    ? 'playlist'
    : n >= 2 && n <= 4
        ? 'playlisty'
        : 'playlistů';

/// Připnutá karta v Knihovně › Playlisty (pod Oblíbenými a Poslechnout
/// později): playlisty, které někdo poslal ze Spotify. Dřív vlastní tab
/// (moc) a pak sekce až úplně dole (nebyla vidět) -- živě nahlášeno.
class SharedPlaylistsCard extends ConsumerWidget {
  const SharedPlaylistsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final count = ref.watch(myPlaylistsProvider).valueOrNull?.where((p) => p.isShared).length;
    return PinnedTile(
      icon: Symbols.link_rounded,
      iconFill: false,
      title: 'Sdílené',
      subtitle: count == null || count == 0 ? 'Od ostatních' : '$count ${_playlists(count)}',
      colors: [scheme.primaryContainer, scheme.secondaryContainer],
      iconBackground: scheme.primary,
      iconColor: scheme.onPrimary,
      textColor: scheme.onPrimaryContainer,
      onTap: () => context.push('/library/shared'),
    );
  }
}

/// Seznam sdílených playlistů (autor, jejich obal) + přidání
/// dalšího odkazu.
class SharedPlaylistsScreen extends ConsumerWidget {
  const SharedPlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(myPlaylistsProvider);
    return Scaffold(
      appBar: SectionAppBar(
        'Sdílené',
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: GlassButton(
              label: 'Přidat',
              icon: Symbols.link_rounded,
              style: GlassButtonStyle.tonal,
              compact: true,
              onPressed: () => showSpotifyLinkDialog(context, ref),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const ShellBarSpace(),
      body: playlists.when(
        data: (all) {
          final shared = [for (final p in all) if (p.isShared) p];
          if (shared.isEmpty) {
            return const EmptyState(
              icon: Symbols.link_rounded,
              message: 'Playlisty, které ti někdo pošle. Vlož odkaz tlačítkem Přidat, do Hledat, '
                  'nebo ho sdílej zkratkou „Do Opentify“.',
            );
          }
          return ListView(
            padding: EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, 32 + navBottomInset(context)),
            children: [
              for (final p in shared)
                MediaCard(
                  layout: MediaCardLayout.row,
                  placeholderIcon: Symbols.queue_music_rounded,
                  artwork: PlaylistArtwork(title: p.title, coverUrls: p.coverUrls, showTitle: false),
                  title: p.title,
                  subtitle: '${p.description ?? 'Ze Spotify'} · ${songsCount(p.itemCount)}',
                  onTap: () => context.push('/playlists/${p.id}'),
                  onLongPress: () => showCollectionActions(
                    context,
                    kind: CollectionKind.playlist,
                    id: p.id,
                    title: p.title,
                    imageUrl: p.coverUrls.firstOrNull,
                    onDelete: () => confirmDeletePlaylist(context, ref, id: p.id, title: p.title),
                  ),
                ),
            ],
          );
        },
        loading: () => const LoadingState(),
        error: (error, stack) => ErrorState(
          message: 'Playlisty se nepodařilo načíst.',
          error: error,
          onRetry: () => ref.invalidate(myPlaylistsProvider),
        ),
      ),
    );
  }
}
