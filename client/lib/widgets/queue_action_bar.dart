import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../state/collection_progress.dart';
import '../theme/design_tokens.dart';
import 'collection_actions.dart';
import 'glass/glass.dart';
import 'track_actions.dart';

/// "Přehrát"/"Zamíchat" řádek nad tracklistem -- sdílený mezi všemi seznamy
/// skladeb (album, playlist, oblíbené, knihovna, interpret, rok v hudbě),
/// většinou přes `TrackCollectionToolbar`, který ho obaluje filtrem/řazením.
class QueueActionBar extends ConsumerWidget {
  const QueueActionBar({
    super.key,
    required this.tracks,
    this.sourceLabel,
    this.albumArtUrl,
    this.artistName,
    this.downloadWholeList = false,
  });

  final List<RecordingModel> tracks;
  final String? sourceLabel;
  final String? albumArtUrl;
  final String? artistName;

  /// Nepoužívá se: Přehrát stahuje jen na vyžádání (hrající a další
  /// skladbu), ne celé album najednou -- uživatel to tak chce.
  final bool downloadWholeList;

  List<NowPlayingInfo> _infosFor(List<RecordingModel> ordered) => ordered
      .map((r) => nowPlayingInfoFor(r, artworkUrl: albumArtUrl, artistNameFallback: artistName))
      .toList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void playAll() {
      if (tracks.isEmpty) return;
      ref.read(audioPlayerControllerProvider.notifier).playQueue(_infosFor(tracks), 0, sourceLabel: sourceLabel);
    }

    void shuffle() {
      if (tracks.isEmpty) return;
      final shuffled = [...tracks]..shuffle();
      // Zamíchané pořadí se jako "kde jsem skončil" neukládá.
      ref
          .read(audioPlayerControllerProvider.notifier)
          .playQueue(_infosFor(shuffled), 0, sourceLabel: sourceLabel, rememberProgress: false);
    }

    // Rozposlouchané album/playlist: "Pokračovat" tam, kde uživatel skončil.
    String? route;
    try {
      route = GoRouterState.of(context).uri.path;
    } catch (_) {}
    final progress = route == null ? null : ref.watch(collectionProgressProvider)[route];
    final resumeIndex = progress == null ? -1 : tracks.indexWhere((t) => t.id == progress.recordingId);
    final canResume = progress != null && resumeIndex >= 0 && (resumeIndex > 0 || progress.positionMs > 20000);
    final nowFromHere = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId)) ==
        progress?.recordingId;
    void resume() => ref.read(audioPlayerControllerProvider.notifier).playQueue(
          _infosFor(tracks),
          resumeIndex,
          sourceLabel: sourceLabel,
          startPosition: Duration(milliseconds: progress!.positionMs),
        );

    // Jedna prominentní akce na obrazovku (HIG Buttons), vedlejší tónová;
    // spojená skupina (M3 Expressive connected button group).
    final group = GlassButtonGroup(
      buttons: [
        GlassButton(
          label: 'Přehrát',
          icon: Symbols.play_arrow_rounded,
          style: GlassButtonStyle.prominent,
          compact: true,
          onPressed: tracks.isEmpty ? null : playAll,
          // Dlouhý stisk: přehrát jako další / do fronty -- nepřeruší, co hraje.
          onLongPress: () => showPlayOptions(context, title: sourceLabel ?? 'Seznam', infos: _infosFor(tracks)),
        ),
        GlassButton(
          label: 'Zamíchat',
          icon: Symbols.shuffle_rounded,
          compact: true,
          onPressed: tracks.isEmpty ? null : shuffle,
        ),
      ],
    );
    if (!canResume || nowFromHere) return group;
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        group,
        GlassButton(
          label: 'Pokračovat · ${resumeIndex + 1}/${tracks.length}',
          icon: Symbols.resume_rounded,
          compact: true,
          onPressed: resume,
          onLongPress: null,
        ),
      ],
    );
  }
}
