import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
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
      ref.read(audioPlayerControllerProvider.notifier).playQueue(_infosFor(shuffled), 0, sourceLabel: sourceLabel);
    }

    // Jedna prominentní akce na obrazovku (HIG Buttons), vedlejší tónová;
    // spojená skupina (M3 Expressive connected button group).
    return GlassButtonGroup(
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
  }
}
