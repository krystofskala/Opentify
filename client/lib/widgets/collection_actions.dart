import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import 'radio_station.dart';
import 'track_actions.dart' show nowPlayingInfoFor;
import '../core/cz_plural.dart';
import 'remove_from_library.dart' show libraryRevisionProvider;

/// Co se dlouhým stiskem otevírá: album, playlist, nebo Oblíbené.
enum CollectionKind { album, playlist, liked }

/// Dlouhý stisk na kartě alba/playlistu: přehrát / přehrát jako další /
/// přidat do fronty / rádio. "Jako další" a "do fronty" NEpřeruší, co zrovna
/// hraje (živě chtěné -- dřív šlo album jen pustit místo aktuální skladby).
///
/// Bere providery z `ProviderScope` kontextu, takže jde volat i ze
/// `StatelessWidget` karet.
Future<void> showCollectionActions(
  BuildContext context, {
  required CollectionKind kind,
  required String id,
  required String title,
  String? subtitle,
  String? imageUrl,
  Widget? artwork,
}) {
  HapticFeedback.selectionClick();
  return showGlassSheet<void>(
    context,
    builder: (sheetContext) => _CollectionActionsSheet(
      hostContext: context,
      kind: kind,
      id: id,
      title: title,
      subtitle: subtitle,
      imageUrl: imageUrl,
      artwork: artwork,
    ),
  );
}

class _CollectionActionsSheet extends ConsumerWidget {
  const _CollectionActionsSheet({
    required this.hostContext,
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.artwork,
  });

  final BuildContext hostContext;
  final CollectionKind kind;
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Widget? artwork;

  // Přes kontejner appky -- načítá se až po zavření sheetu, jeho `ref` už
  // v tu chvíli neplatí.
  Future<List<NowPlayingInfo>> _load(ProviderContainer container) async {
    final List<RecordingModel> tracks = switch (kind) {
      CollectionKind.album => await container.read(catalogRepositoryProvider).getReleaseTracks(id),
      CollectionKind.playlist => (await container.read(playlistsRepositoryProvider).get(id)).items,
      CollectionKind.liked => (await container.read(libraryRepositoryProvider).likedSongs()).items,
    };
    return [
      for (final t in tracks) nowPlayingInfoFor(t, artworkUrl: kind == CollectionKind.album ? imageUrl : null),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.maybeOf(hostContext);
    final container = ProviderScope.containerOf(context, listen: false);
    final controller = container.read(audioPlayerControllerProvider.notifier);
    final what = switch (kind) {
      CollectionKind.album => 'album',
      _ => 'playlist',
    };

    void toast(String text) =>
        messenger?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));

    // Sheet zavřít hned, skladby dotáhnout potom (album z MusicBrainz může
    // chvíli trvat) -- chyba jen jako toast.
    void run(Future<void> Function(List<NowPlayingInfo> infos) action) {
      Navigator.of(context).pop();
      _load(container).then((infos) async {
        if (infos.isEmpty) {
          toast('Není co přehrát');
          return;
        }
        await action(infos);
      }).catchError((Object _) => toast('Nepodařilo se načíst skladby, zkus to znovu'));
    }

    String songs(int n) => songsCount(n);

    return SafeArea(
      child: GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Row(
                  children: [
                    ClipPath(
                      clipper: ShapeBorderClipper(shape: AppShapes.sm),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: artwork ??
                            ArtworkImage(
                              url: imageUrl,
                              icon: kind == CollectionKind.album ? Symbols.album_rounded : Symbols.queue_music_rounded,
                              iconSize: 22,
                            ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                          if (subtitle != null)
                            Text(subtitle!,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              const Divider(height: 1),
              _Row(
                icon: Symbols.play_arrow_rounded,
                label: 'Přehrát',
                onTap: () => run((infos) => controller.playQueue(infos, 0, sourceLabel: title)),
              ),
              _Row(
                icon: Symbols.playlist_play_rounded,
                label: 'Přehrát jako další',
                onTap: () => run((infos) async {
                  await controller.playNextAll(infos, sourceLabel: title);
                  toast('Jako další: ${songs(infos.length)} z „$title“');
                }),
              ),
              _Row(
                icon: Symbols.queue_music_rounded,
                label: 'Přidat do fronty',
                onTap: () => run((infos) async {
                  await controller.addAllToQueue(infos, sourceLabel: title);
                  toast('Do fronty: ${songs(infos.length)} z „$title“');
                }),
              ),
              if (kind == CollectionKind.album)
                _Row(
                  icon: Symbols.library_add_rounded,
                  label: 'Přidat do knihovny',
                  // `run` nejdřív načte tracklist (skladby se tím zapíšou do
                  // katalogu), pak se album přidá a stáhne.
                  onTap: () => run((infos) async {
                    try {
                      await container.read(apiClientProvider).postJson('/library/albums/$id');
                      container.read(libraryRevisionProvider.notifier).state++;
                      toast('„$title“ je v knihovně (${songs(infos.length)})');
                    } catch (_) {
                      toast('Album se nepodařilo přidat');
                    }
                  }),
                ),
              _Row(
                icon: Symbols.radio_rounded,
                label: 'Přejít na rádio',
                onTap: () async {
                  Navigator.of(context).pop();
                  // Oblíbené mají v "Pokračovat" jen id "liked" -- skutečné
                  // id playlistu až z knihovny.
                  final seedId = kind == CollectionKind.liked
                      ? (await container.read(libraryRepositoryProvider).likedSongs()).id
                      : id;
                  if (!hostContext.mounted) return;
                  goToRadio(hostContext, kind == CollectionKind.album ? RadioSeed.album : RadioSeed.playlist, seedId);
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
                child: Text(
                  '„Jako další“ a „do fronty“ nepřeruší, co zrovna hraje ($what zůstane celé).',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      shape: AppShapes.md,
      leading: Icon(icon),
      title: Text(label),
      onTap: onTap,
    );
  }
}

/// Dlouhý stisk na "Přehrát" nad seznamem skladeb: skladby už jsou načtené,
/// jen nabídnout, KAM je dát (jako další / na konec fronty).
Future<void> showPlayOptions(BuildContext context, {required String title, required List<NowPlayingInfo> infos}) {
  if (infos.isEmpty) return Future.value();
  HapticFeedback.selectionClick();
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(audioPlayerControllerProvider.notifier);
  final messenger = ScaffoldMessenger.maybeOf(context);
  String songs(int n) => songsCount(n);
  void toast(String text) =>
      messenger?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  return showGlassSheet<void>(
    context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      void run(Future<void> Function() action) {
        Navigator.of(sheetContext).pop();
        action();
      }

      return SafeArea(
        child: GlassSheet(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Text('$title · ${songs(infos.length)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Divider(height: 1),
                _Row(
                  icon: Symbols.play_arrow_rounded,
                  label: 'Přehrát',
                  onTap: () => run(() => controller.playQueue(infos, 0, sourceLabel: title)),
                ),
                _Row(
                  icon: Symbols.playlist_play_rounded,
                  label: 'Přehrát jako další',
                  onTap: () => run(() async {
                    await controller.playNextAll(infos, sourceLabel: title);
                    toast('Jako další: ${songs(infos.length)} z „$title“');
                  }),
                ),
                _Row(
                  icon: Symbols.queue_music_rounded,
                  label: 'Přidat do fronty',
                  onTap: () => run(() async {
                    await controller.addAllToQueue(infos, sourceLabel: title);
                    toast('Do fronty: ${songs(infos.length)} z „$title“');
                  }),
                ),
                _Row(
                  icon: Symbols.shuffle_rounded,
                  label: 'Zamíchat a přidat do fronty',
                  onTap: () => run(() async {
                    await controller.addAllToQueue([...infos]..shuffle(), sourceLabel: title);
                    toast('Do fronty zamíchaně: ${songs(infos.length)}');
                  }),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
