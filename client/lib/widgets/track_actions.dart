import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/share_link.dart';
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
      messenger?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  try {
    final link = ready ?? await load();
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
    // Klasická knihovna profilu: co si sám přidal (ne co jen poslouchal).
    final inLibrary = ref.watch(libraryIdsProvider).valueOrNull?.contains(recording.id) ?? false;

    void run(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    void toast(String text) =>
        messenger?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
    // Odkaz ke sdílení načíst hned (Safari sdílí jen přímo po klepnutí).
    final ShareTarget shareTarget = (kind: 'recordings', id: recording.id);
    final shareLinkAsync = ref.watch(shareLinkProvider(shareTarget));

    return SafeArea(
      child: GlassSheet(
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
                    toast('Zařazeno jako další');
                  }),
                ),
                _Item(
                  icon: Symbols.queue_music_rounded,
                  label: 'Přidat do fronty',
                  onTap: () => run(() {
                    controller.addToQueue(info);
                    toast('Přidáno do fronty');
                  }),
                ),
                _Item(
                  icon: isLiked ? Symbols.heart_minus_rounded : Symbols.favorite_rounded,
                  label: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
                  onTap: () => run(() => ref.read(likedSongsControllerProvider.notifier).toggle(recording.id)),
                ),
                _Item(
                  icon: Symbols.playlist_add_rounded,
                  label: 'Přidat do playlistu',
                  onTap: () => run(() => showAddToPlaylistSheet(hostContext, recordingId: recording.id)),
                ),
                _Item(
                  icon: isLater ? Symbols.event_busy_rounded : Symbols.schedule_rounded,
                  label: isLater ? 'Odebrat z Poslechnout později' : 'Poslechnout později',
                  onTap: () => run(
                    () => ref.read(listenLaterProvider.notifier).toggle(hostContext, LaterKind.track, recording.id),
                  ),
                ),
                _Item(
                  icon: Symbols.ios_share_rounded,
                  label: 'Sdílet',
                  onTap: () {
                    final link = shareLinkAsync.valueOrNull;
                    run(() => shareWithToast(link, messenger, () => ref.read(shareLinkProvider(shareTarget).future)));
                  },
                ),
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
                if (inLibrary)
                  _Item(
                    icon: Symbols.delete_rounded,
                    label: 'Odebrat z knihovny',
                    destructive: true,
                    onTap: () => run(() => confirmRemoveFromLibrary(hostContext, [recording])),
                  ),
                for (final action in extraActions)
                  _Item(
                    icon: action.icon,
                    label: action.label,
                    destructive: action.destructive,
                    onTap: () => run(action.onSelected),
                  ),
              ],
            ),
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
