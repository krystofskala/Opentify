import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/share_link.dart';
import '../features/artist/artist_support.dart' show openExternal;
import '../data/listen_later_repository.dart' show LaterKind;
import '../state/listen_later_controller.dart';
import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../state/liked_songs_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'add_to_playlist_sheet.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import 'remove_from_library.dart';
import 'radio_station.dart';
import '../state/library_scope.dart';
import '../state/offline_controller.dart';
import '../state/auth_controller.dart';
import '../state/providers.dart' show apiClientProvider;
import 'verify_track_sheet.dart';
import 'share_sheet.dart';
import 'toast.dart';

/// `RecordingModel` -> `NowPlayingInfo` -- jediné místo, kde se tahle
/// konverze dělá (dřív ji měl zvlášť `TrackTile`, `QueueActionBar`, Search).
NowPlayingInfo nowPlayingInfoFor(RecordingModel r, {String? artworkUrl, String? artistNameFallback}) => NowPlayingInfo(
      recordingId: r.id,
      title: r.title,
      artistName: r.artistName ?? artistNameFallback,
      artistId: r.artistId,
      releaseId: r.releaseId,
      artworkUrl: artworkUrl,
    );

/// Doplňková akce kontextového menu specifická pro místo, odkud se volá
/// (např. "Odebrat z playlistu" jen ve vlastním playlistu).
class TrackMenuAction {
  const TrackMenuAction({required this.icon, required this.label, required this.onSelected, this.destructive = false});

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;
}

/// Jedno sdílené kontextové menu skladby -- dlouhý stisk / pravé tlačítko
/// na `TrackTile` kdekoliv v appce i "⋯" na detailu skladby. Dřív měl
/// `TrackTile` vlastní tři položky a přehrávač jiné -- teď všude stejné.
Future<void> showTrackActionsSheet(
  BuildContext context, {
  required RecordingModel recording,
  String? artworkUrl,
  String? artistNameFallback,
  List<TrackMenuAction> extraActions = const [],
}) {
  return showGlassSheet(
    context,
    builder: (sheetContext) => _TrackActionsSheet(
      recording: recording,
      artworkUrl: artworkUrl,
      artistNameFallback: artistNameFallback,
      extraActions: extraActions,
      // Router/messenger z VOLAJÍCÍHO contextu -- sheet se po výběru zavře,
      // navigace musí jít přes stránku pod ním.
      hostContext: context,
    ),
  );
}

/// Sdílí univerzální odkaz (song.link). Odkaz už načtený -> sdílí hned v
/// rámci klepnutí; jinak ho dotáhne a zkopíruje (systémové sdílení by po
/// síťovém čekání Safari odmítl).
Future<void> shareWithToast(
  ShareLink? ready,
  ScaffoldMessengerState? messenger,
  Future<ShareLink> Function() load,
) async {
  void toast(String text) =>
      showToast(messenger, text);
  try {
    final link = ready ?? await load();
    if (link.url == null && link.youtubeUrl == null) {
      toast('Tahle skladba je jen v Opentify – pošli ji přes „Poslat v Opentify“');
      return;
    }
    final outcome = await shareLink(link);
    if (outcome == ShareOutcome.copied) toast('Odkaz zkopírován – otevře se v jakékoliv hudební appce');
    if (outcome == ShareOutcome.failed) toast('Odkaz se nepodařilo zkopírovat: ${link.url}');
  } catch (_) {
    toast('Skladbu se nepodařilo najít pro sdílení');
  }
}

class _TrackActionsSheet extends ConsumerWidget {
  const _TrackActionsSheet({
    required this.recording,
    required this.artworkUrl,
    required this.artistNameFallback,
    required this.extraActions,
    required this.hostContext,
  });

  final RecordingModel recording;
  final String? artworkUrl;
  final String? artistNameFallback;
  final List<TrackMenuAction> extraActions;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final info = nowPlayingInfoFor(recording, artworkUrl: artworkUrl, artistNameFallback: artistNameFallback);
    final artistName = recording.artistName ?? artistNameFallback;
    final isLiked =
        ref.watch(likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(recording.id) ?? false));
    final messenger = ScaffoldMessenger.maybeOf(hostContext);
    final isLater =
        ref.watch(listenLaterProvider.select((s) => s.valueOrNull?.find(LaterKind.track, recording.id) != null));
    final offlineState = ref.watch(offlineControllerProvider);
    final isOffline = offlineState.tracks.containsKey(recording.id);
    final offlinePending = offlineState.pending.containsKey(recording.id);
    // Klasická knihovna profilu: co si sám přidal (ne co jen poslouchal).
    final inLibrary = ref.watch(libraryIdsProvider).valueOrNull?.contains(recording.id) ?? false;
    final isDisliked = ref.watch(dislikedProvider.select((d) => d.contains(recording.id)));

    void run(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    void toast(String text) =>
        showToast(messenger, text);
    // Odkaz ke sdílení načíst hned (Safari sdílí jen přímo po klepnutí).
    final ShareTarget shareTarget = (kind: 'recordings', id: recording.id);
    final shareLinkAsync = ref.watch(shareLinkProvider(shareTarget));

    return GlassSheet(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: SingleChildScrollView(
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
                        child: ArtworkImage(url: artworkUrl, icon: Symbols.music_note_rounded, iconSize: 22),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(recording.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                          if (artistName != null)
                            Text(artistName,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              const Divider(height: 1),
              // Pořadí skupin jako v každém menu (audit UI): fronta · uložit ·
              // objevovat · Sdílet… · odebrat (červeně) · admin.
              _Item(
                icon: Symbols.play_arrow_rounded,
                label: 'Přehrát',
                onTap: () => run(() => controller.playTrack(info)),
              ),
              _Item(
                icon: Symbols.playlist_play_rounded,
                label: 'Přehrát jako další',
                onTap: () => run(() {
                  controller.playNext(info);
                  toast('Jako další: ${recording.title}');
                }),
              ),
              _Item(
                icon: Symbols.add_to_queue_rounded,
                label: 'Přidat do fronty',
                onTap: () => run(() {
                  controller.addToQueue(info);
                  toast('Do fronty: ${recording.title}');
                }),
              ),
              const _Divider(),
              _Item(
                icon: isLiked ? Symbols.heart_minus_rounded : Symbols.favorite_rounded,
                label: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
                onTap: () => run(() => ref.read(likedSongsControllerProvider.notifier).toggle(recording.id)),
              ),
              _Item(
                icon: Symbols.playlist_add_rounded,
                label: 'Přidat do playlistu…',
                onTap: () => run(() => showAddToPlaylistSheet(hostContext, recordingId: recording.id)),
              ),
              _Item(
                icon: isLater ? Symbols.event_busy_rounded : Symbols.schedule_rounded,
                label: isLater ? 'Odebrat z „Na později“' : 'Uložit na později',
                onTap: () => run(
                  () => ref.read(listenLaterProvider.notifier).toggle(hostContext, LaterKind.track, recording.id),
                ),
              ),
              if (!inLibrary)
                _Item(
                  icon: Symbols.library_add_rounded,
                  label: 'Přidat do knihovny',
                  onTap: () => run(() async {
                    try {
                      await addTrackToLibrary(ref, recording.id);
                      toast('Přidáno do knihovny');
                    } catch (_) {
                      toast('Nepodařilo se přidat do knihovny');
                    }
                  }),
                ),
              _Item(
                icon: isOffline
                    ? Symbols.mobile_off_rounded
                    : (offlinePending ? Symbols.downloading_rounded : Symbols.download_for_offline_rounded),
                label: isOffline
                    ? 'Smazat ze zařízení'
                    : (offlinePending ? 'Stahuje se do zařízení…' : 'Stáhnout do zařízení'),
                onTap: () => run(() {
                  final offline = ref.read(offlineControllerProvider.notifier);
                  if (isOffline) {
                    offline.remove(recording.id);
                    toast('Smazáno ze zařízení');
                  } else if (!offlinePending) {
                    offline.add([info]);
                    toast('Stahuje se do zařízení');
                  }
                }),
              ),
              const _Divider(),
              _Item(
                icon: Symbols.radio_rounded,
                label: 'Přejít na rádio',
                onTap: () => run(() => goToRadio(hostContext, RadioSeed.track, recording.id)),
              ),
              if (recording.releaseId != null)
                _Item(
                  icon: Symbols.album_rounded,
                  label: 'Přejít na album',
                  onTap: () => run(() => hostContext.push('/releases/${recording.releaseId}?track=${recording.id}')),
                ),
              if (recording.artistId != null)
                _Item(
                  icon: Symbols.person_rounded,
                  label: 'Přejít na interpreta',
                  onTap: () => run(() => hostContext.push('/artists/${recording.artistId}')),
                ),
              if (shareLinkAsync.valueOrNull?.youtubeUrl case final yt?)
                _Item(
                  icon: Symbols.smart_display_rounded,
                  label: 'Zdrojové video na YouTube',
                  onTap: () => run(() => openExternal(yt)),
                ),
              const _Divider(),
              _Item(
                icon: Symbols.ios_share_rounded,
                label: 'Sdílet…',
                onTap: () => run(() => showShareSheet(
                      hostContext,
                      title: recording.title,
                      artistName: recording.artistName ?? artistNameFallback,
                      opentifyPath: '/track/${recording.id}',
                      external: shareTarget,
                    )),
              ),
              const _Divider(),
              for (final action in extraActions)
                _Item(
                  icon: action.icon,
                  label: action.label,
                  destructive: action.destructive,
                  onTap: () => run(action.onSelected),
                ),
              _Item(
                icon: isDisliked ? Symbols.heart_check_rounded : Symbols.heart_broken_rounded,
                label: isDisliked ? 'Zrušit „Nelíbí se mi“' : 'Nelíbí se mi',
                onTap: () => run(() async {
                  final ok = await ref.read(dislikedProvider.notifier).toggle(recording.id);
                  if (ok) toast(isDisliked ? 'Zrušeno: Nelíbí se mi' : 'Označeno: Nelíbí se mi');
                }),
              ),
              // Stáhla se jiná verze (live, cover, úplně jiná píseň): zdroj se
              // zapamatuje jako špatný a stáhne se jiný.
              if (inLibrary)
                _Item(
                  icon: Symbols.sync_problem_rounded,
                  label: 'Špatná verze – stáhnout jinou',
                  onTap: () => run(() async {
                    try {
                      await ref.read(apiClientProvider).postJson('/library/tracks/${recording.id}/wrong-version');
                      ref.invalidate(libraryIdsProvider);
                      toast('Stahuju jinou verzi „${recording.title}“');
                      if (ref.read(audioPlayerControllerProvider).nowPlaying?.recordingId == recording.id) {
                        await controller.retryCurrent();
                      }
                    } catch (e) {
                      toast('Nepodařilo se: $e');
                    }
                  }),
                ),
              if (inLibrary)
                _Item(
                  icon: Symbols.delete_rounded,
                  label: 'Odebrat z knihovny',
                  destructive: true,
                  onTap: () => run(() => confirmRemoveFromLibrary(hostContext, [recording])),
                ),
              // Admin: špatně stažená skladba? Shazam ji poslechne na serveru.
              if (ref.watch(authProvider).valueOrNull?.user?.role == 'admin')
                _Item(
                  icon: Symbols.graphic_eq_rounded,
                  label: 'Něco nesedí? Zkontrolovat Shazamem',
                  onTap: () => run(() => checkTrackWithShazam(hostContext, ref, recording)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.label, required this.onTap, this.destructive = false});

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

/// Oddělovač skupin v menu (fronta · uložit · objevovat · sdílet · odebrat).
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xxs, horizontal: AppSpacing.md),
        child: Divider(height: 1),
      );
}
