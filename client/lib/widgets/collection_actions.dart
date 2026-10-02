import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import 'radio_station.dart';
import 'share_sheet.dart';
import 'remove_from_library.dart' show confirmRemoveFromLibrary;
import 'track_actions.dart' show nowPlayingInfoFor;
import '../core/cz_plural.dart';
import 'remove_from_library.dart' show libraryRevisionProvider;
import '../state/offline_controller.dart';
import '../state/provisioning_controller.dart';
import '../state/auth_controller.dart';
import '../state/listen_later_controller.dart' show listenLaterProvider;
import '../data/listen_later_repository.dart' show LaterKind;
import 'toast.dart';

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
  String? fromArtistId,
  VoidCallback? onNotArtist,
  String? artistId,
  String? artistName,
  bool? inLibrary,
  bool isRadio = false,
  VoidCallback? onSaveCopy,
  VoidCallback? onDelete,
  VoidCallback? onEdit,
  VoidCallback? onInvite,
  VoidCallback? onLeave,
  String? deleteLabel,
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
      fromArtistId: fromArtistId,
      onNotArtist: onNotArtist,
      artistId: artistId,
      artistName: artistName,
      inLibrary: inLibrary,
      isRadio: isRadio,
      onSaveCopy: onSaveCopy,
      onDelete: onDelete,
      onEdit: onEdit,
      onInvite: onInvite,
      onLeave: onLeave,
      deleteLabel: deleteLabel,
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
    this.fromArtistId,
    this.onNotArtist,
    this.artistId,
    this.artistName,
    this.inLibrary,
    this.isRadio = false,
    this.onSaveCopy,
    this.onDelete,
    this.onEdit,
    this.onInvite,
    this.onLeave,
    this.deleteLabel,
  });

  final BuildContext hostContext;
  final CollectionKind kind;
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Widget? artwork;

  /// Album otevřené ze stránky interpreta: admin ho může vyřadit jako
  /// album stejnojmenné cizí kapely (Deezer je občas slučuje).
  final String? fromArtistId;
  final VoidCallback? onNotArtist;

  /// Album: interpret (Přejít na interpreta, název do sdílení).
  final String? artistId;
  final String? artistName;

  /// Album: je celé v knihovně? `null` = nevíme (nabídne se Přidat).
  final bool? inLibrary;

  /// Rádio-playlist: "Přejít na rádio" nenabízet (už je rádio).
  final bool isRadio;

  /// Cizí playlist (mix, žebříček, sdílený): uložit kopii do mých.
  final VoidCallback? onSaveCopy;

  /// Vlastní playlist: smazat (dole, červeně).
  final VoidCallback? onDelete;

  /// Vlastní playlist: název, popis, obal.
  final VoidCallback? onEdit;

  /// Vlastní playlist: pozvat do společného (odkaz).
  final VoidCallback? onInvite;

  /// Člen společného playlistu: opustit.
  final VoidCallback? onLeave;

  /// Vlastní text pro `onDelete` (Odebrat z knihovny / Opustit...).
  final String? deleteLabel;

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
        showToast(messenger, text);

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

    return GlassSheet(
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
              icon: Symbols.add_to_queue_rounded,
              label: 'Přidat do fronty',
              onTap: () => run((infos) async {
                await controller.addAllToQueue(infos, sourceLabel: title);
                toast('Do fronty: ${songs(infos.length)} z „$title“');
              }),
            ),
            _Row(
              icon: Symbols.shuffle_rounded,
              label: 'Zamíchat a přidat do fronty',
              onTap: () => run((infos) async {
                await controller.addAllToQueue([...infos]..shuffle(), sourceLabel: title);
                toast('Do fronty zamíchaně: ${songs(infos.length)}');
              }),
            ),
            const _MenuDivider(),
            if (onInvite != null)
              _Row(
                icon: Symbols.group_add_rounded,
                label: 'Pozvat do společného playlistu…',
                onTap: () {
                  Navigator.of(context).pop();
                  onInvite!();
                },
              ),
            if (onEdit != null)
              _Row(
                icon: Symbols.edit_rounded,
                label: 'Upravit název, popis a obal…',
                onTap: () {
                  Navigator.of(context).pop();
                  onEdit!();
                },
              ),
            if (onSaveCopy != null)
              _Row(
                icon: Symbols.library_add_rounded,
                label: 'Uložit do mých playlistů',
                onTap: () {
                  Navigator.of(context).pop();
                  onSaveCopy!();
                },
              ),
            // Celé album/playlist stáhnout na server najednou (Přehrát
            // stahuje jen hranou a další skladbu).
            _Row(
              icon: Symbols.cloud_download_rounded,
              label: kind == CollectionKind.album ? 'Stáhnout celé album' : 'Stáhnout všechny skladby',
              onTap: () => run((infos) async {
                if (kind == CollectionKind.album) {
                  // Album jako celek: jedna složka ze Soulseeku (jedna verze
                  // od jednoho člověka), zbytek po skladbách.
                  toast('Hledám album na Soulseeku…');
                  try {
                    final res = await container.read(apiClientProvider).postJson(
                          '/library/albums/$id/download',
                          timeout: const Duration(seconds: 60),
                        );
                    toast(res['found'] == true
                        ? 'Celé album z jedné složky: ${res['matched']}/${res['total']} skladeb, zbytek dohledám'
                        : 'Album jako celek jsem nenašel – stahuju po skladbách');
                  } catch (_) {
                    toast('Album se nepodařilo zařadit ke stažení');
                  }
                  return;
                }
                final provisioning = container.read(provisioningControllerProvider.notifier);
                for (final info in infos) {
                  unawaited(provisioning.provision(info.recordingId));
                }
                toast('Stahuje se: ${songs(infos.length)}');
              }),
            ),
            _Row(
              icon: Symbols.download_for_offline_rounded,
              label: 'Stáhnout do zařízení',
              onTap: () => run((infos) async {
                container.read(offlineControllerProvider.notifier).add(infos);
                toast('Stahuje se do zařízení: ${songs(infos.length)}');
              }),
            ),
            if (kind == CollectionKind.album && inLibrary != true)
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
            if (kind == CollectionKind.album)
              Builder(builder: (context) {
                final later = ref.watch(
                  listenLaterProvider.select((s) => s.valueOrNull?.find(LaterKind.album, id) != null),
                );
                return _Row(
                  icon: later ? Symbols.event_busy_rounded : Symbols.schedule_rounded,
                  label: later ? 'Odebrat z „Na později“' : 'Uložit na později',
                  onTap: () {
                    Navigator.of(context).pop();
                    container.read(listenLaterProvider.notifier).toggle(hostContext, LaterKind.album, id);
                  },
                );
              }),
            const _MenuDivider(),
            if (!isRadio)
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
            if (kind == CollectionKind.album && artistId != null)
              _Row(
                icon: Symbols.person_rounded,
                label: 'Přejít na interpreta',
                onTap: () {
                  Navigator.of(context).pop();
                  hostContext.push('/artists/$artistId');
                },
              ),
            if (kind != CollectionKind.liked) ...[
              const _MenuDivider(),
              _Row(
                icon: Symbols.ios_share_rounded,
                label: 'Sdílet…',
                onTap: () {
                  Navigator.of(context).pop();
                  showShareSheet(
                    hostContext,
                    title: title,
                    artistName: kind == CollectionKind.album ? (artistName ?? subtitle) : null,
                    opentifyPath: kind == CollectionKind.album ? '/releases/$id' : '/playlists/$id',
                    external: kind == CollectionKind.album ? (kind: 'releases', id: id) : null,
                  );
                },
              ),
            ],
            if (kind == CollectionKind.album && inLibrary == true)
              _Row(
                icon: Symbols.delete_rounded,
                label: 'Odebrat z knihovny',
                destructive: true,
                onTap: () {
                  Navigator.of(context).pop();
                  _load(container).then((_) async {
                    final tracks = await container.read(catalogRepositoryProvider).getReleaseTracks(id);
                    if (hostContext.mounted) await confirmRemoveFromLibrary(hostContext, tracks);
                  });
                },
              ),
            if (onLeave != null)
              _Row(
                icon: Symbols.logout_rounded,
                label: 'Opustit společný playlist',
                destructive: true,
                onTap: () {
                  Navigator.of(context).pop();
                  onLeave!();
                },
              ),
            if (onDelete != null)
              _Row(
                icon: Symbols.delete_rounded,
                label: deleteLabel ?? (kind == CollectionKind.album ? 'Smazat album' : 'Smazat playlist'),
                destructive: true,
                onTap: () {
                  Navigator.of(context).pop();
                  onDelete!();
                },
              ),
            if (kind == CollectionKind.album &&
                fromArtistId != null &&
                ref.watch(authProvider).valueOrNull?.user?.role == 'admin')
              _Row(
                icon: Symbols.person_off_rounded,
                label: 'Nepatří k tomuto interpretovi',
                onTap: () async {
                  Navigator.of(context).pop();
                  try {
                    await container
                        .read(apiClientProvider)
                        .postJson('/catalog/artists/$fromArtistId/releases/$id/not-artist');
                    onNotArtist?.call();
                    toast('„$title“ vyřazeno z interpreta');
                  } catch (_) {
                    toast('Nepodařilo se vyřadit');
                  }
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
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.onTap, this.destructive = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      dense: true,
      shape: AppShapes.md,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }
}

/// Oddělovač skupin (fronta · uložit · objevovat · sdílet · odebrat).
class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xxs, horizontal: AppSpacing.md),
        child: Divider(height: 1),
      );
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
      showToast(messenger, text);
  return showGlassSheet<void>(
    context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      void run(Future<void> Function() action) {
        Navigator.of(sheetContext).pop();
        action();
      }

      return GlassSheet(
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
              // Celé album / playlist do offline knihovny v zařízení.
              _Row(
                icon: Symbols.download_for_offline_rounded,
                label: 'Stáhnout do zařízení',
                onTap: () => run(() async {
                  container.read(offlineControllerProvider.notifier).add(infos);
                  toast('Stahuje se do zařízení: ${songs(infos.length)}');
                }),
              ),
            ],
          ),
        ),
      );
    },
  );
}
