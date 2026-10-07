import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/home_repository.dart';
import '../../models/search_result.dart';
import '../../state/audio_player_controller.dart' show audioPlayerControllerProvider;
import '../../state/auto_continue.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import '../../widgets/track_actions.dart' show nowPlayingInfoFor;
import '../profile/profile_screen.dart' show openProfileSection;
import 'home_layout_sheet.dart' show showHomeLayoutSheet;

/// Domů nového profilu (opentify-notes/domu-novacek-struktura-2026-10-07.md):
/// Album na celý poslech, karty Import + Uprav Domů na konci a „Z čeho mám
/// začít?“ pro Pusť teď bez dat.

/// Album na celý poslech: velký obal, proč tohle album, Přehrát celé album
/// (popořadě, po konci ticho -- žádné automatické pokračování).
class AlbumSpotlightCard extends ConsumerStatefulWidget {
  const AlbumSpotlightCard({super.key, required this.title, required this.album});
  final String title;
  final HomeAlbumCard album;

  @override
  ConsumerState<AlbumSpotlightCard> createState() => _AlbumSpotlightCardState();
}

class _AlbumSpotlightCardState extends ConsumerState<AlbumSpotlightCard> {
  bool _loading = false;

  Future<void> _play() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _loading = true);
    try {
      final tracks = await ref.read(catalogRepositoryProvider).getReleaseTracks(widget.album.id);
      if (tracks.isEmpty) {
        showToast(messenger, 'Album se nepodařilo načíst.');
        return;
      }
      await ref
          .read(audioPlayerControllerProvider.notifier)
          .playQueue([for (final t in tracks) nowPlayingInfoFor(t)], 0, sourceLabel: widget.album.title);
    } catch (e) {
      showToast(messenger, 'Album se nepodařilo pustit: ${humanError(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final year = (album.releaseDate ?? '').length >= 4 ? album.releaseDate!.substring(0, 4) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(widget.title),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            onTap: () => context.push('/releases/${album.id}'),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  child: SizedBox(
                    width: 132,
                    height: 132,
                    child: ArtworkImage(url: album.images.isEmpty ? null : album.images.first),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                      Text(
                        [album.artistName, year].whereType<String>().join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if ((album.badge ?? '').isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(album.badge!, maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                      GlassButton(
                        label: _loading ? 'Načítám…' : 'Přehrát celé album',
                        icon: Symbols.play_arrow_rounded,
                        compact: true,
                        onPressed: _loading ? null : _play,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Karty na konci Domů nováčka: „Přines si svou hudbu“ a „Co chceš mít na
/// Domů?“ vedle sebe. Obě jde zavřít („Teď ne“ + Vrátit) a zmizí samy s daty.
class NewcomerSetupCards extends ConsumerWidget {
  const NewcomerSetupCards({super.key, required this.cards});
  final List<String> cards;

  Future<void> _dismiss(BuildContext context, WidgetRef ref, String card, {bool undo = false}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(apiClientProvider).postJson('/home/newcomer/dismiss', body: {'card': card, 'undo': undo});
      ref.invalidate(homeProvider);
      if (!undo) {
        showToast(
          messenger,
          'Najdeš to v Profilu.',
          action: SnackBarAction(label: 'Vrátit', onPressed: () => _dismiss(context, ref, card, undo: true)),
        );
      }
    } catch (e) {
      showToast(messenger, 'Nepovedlo se: ${humanError(e)}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = <Widget>[
      if (cards.contains('import'))
        _SetupTile(
          icon: Symbols.download_rounded,
          title: 'Přines si svou hudbu',
          text: 'Historie a playlisty ze Spotify, Apple Music nebo YouTube – doporučení pak sedí hned.',
          action: 'Importovat',
          onAction: () => openProfileSection(context, ref, 'music'),
          onDismiss: () => _dismiss(context, ref, 'import'),
        ),
      if (cards.contains('customize'))
        _SetupTile(
          icon: Symbols.dashboard_customize_rounded,
          title: 'Co chceš mít na Domů?',
          text: 'Vyber si sekce a jejich pořadí – nic není povinné.',
          action: 'Upravit Domů',
          onAction: () => showHomeLayoutSheet(context),
          onDismiss: () => _dismiss(context, ref, 'customize'),
        ),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Vedle sebe, na úzkém telefonu pod sebou.
          if (constraints.maxWidth >= 560 && tiles.length == 2) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Expanded(child: tiles[0]), const SizedBox(width: AppSpacing.sm), Expanded(child: tiles[1])],
              ),
            );
          }
          return Column(
            children: [
              for (final t in tiles) Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: t),
            ],
          );
        },
      ),
    );
  }
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({
    required this.icon,
    required this.title,
    required this.text,
    required this.action,
    required this.onAction,
    required this.onDismiss,
  });

  final IconData icon;
  final String title;
  final String text;
  final String action;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: 6),
            Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                GlassButton(label: action, compact: true, onPressed: onAction),
                const SizedBox(width: AppSpacing.sm),
                GlassButton(label: 'Teď ne', compact: true, style: GlassButtonStyle.plain, onPressed: onDismiss),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// „Z čeho mám začít?“ -- Pusť teď u profilu bez jediného poslechu:
/// vyhledá interpreta nebo skladbu (žádná nabízená jména) a pustí od toho.
Future<void> showPlayNowStartSheet(BuildContext context, WidgetRef ref) async {
  final picked = await showGlassSheet<SearchResultItem>(
    context,
    builder: (sheet) => const GlassSheet(child: _StartPicker()),
  );
  if (picked == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final reason = await ref.read(autoContinueProvider).start(
          startArtistId: picked.entityType == SearchEntityType.artist ? picked.id : null,
          startRecordingId: picked.entityType == SearchEntityType.recording ? picked.id : null,
        );
    if (reason != null && reason.isNotEmpty) showToast(messenger, reason);
  } catch (e) {
    showToast(messenger, 'Pusť teď se nepovedlo: ${humanError(e)}');
  }
}

class _StartPicker extends ConsumerStatefulWidget {
  const _StartPicker();

  @override
  ConsumerState<_StartPicker> createState() => _StartPickerState();
}

class _StartPickerState extends ConsumerState<_StartPicker> {
  Timer? _debounce;
  String _query = '';
  List<SearchResultItem> _results = const [];
  bool _loading = false;

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q.trim()));
  }

  Future<void> _search(String q) async {
    if (q.length < 2) {
      setState(() => _results = const []);
      return;
    }
    setState(() {
      _query = q;
      _loading = true;
    });
    try {
      final repo = ref.read(catalogRepositoryProvider);
      final artists = await repo.search(q, entityType: 'artist', limit: 4);
      final tracks = await repo.search(q, entityType: 'recording', limit: 6);
      if (!mounted || q != _query) return;
      setState(() => _results = [...artists.results, ...tracks.results]);
    } catch (_) {
      if (mounted) setState(() => _results = const []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Z čeho mám začít?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Napiš interpreta nebo skladbu, kterou máš rád – navážu podobnou hudbou.', style: muted),
          const SizedBox(height: AppSpacing.sm),
          GlassSearchField(
            hintText: 'Interpret nebo skladba',
            autofocus: true,
            glass: false,
            showCancel: false,
            onChanged: _onChanged,
            onSubmitted: (q) => _search(q.trim()),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final r in _results)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SizedBox(
                      width: 44,
                      height: 44,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(r.entityType == SearchEntityType.artist ? 22 : 6),
                        child: ArtworkImage(
                          url: r.imageUrl,
                          icon: r.entityType == SearchEntityType.artist ? Symbols.person_rounded : Symbols.music_note_rounded,
                          iconSize: 20,
                        ),
                      ),
                    ),
                    title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      r.entityType == SearchEntityType.artist ? 'Interpret' : (r.artistName ?? r.subtitle ?? 'Skladba'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop(r),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
