import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../theme/design_tokens.dart';
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
  });

  final List<RecordingModel> tracks;
  final String? sourceLabel;
  final String? albumArtUrl;
  final String? artistName;

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

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        FilledButton.icon(
          onPressed: tracks.isEmpty ? null : playAll,
          icon: const Icon(Symbols.play_arrow_rounded),
          label: const Text('Přehrát'),
        ),
        FilledButton.tonalIcon(
          onPressed: tracks.isEmpty ? null : shuffle,
          icon: const Icon(Symbols.shuffle_rounded),
          label: const Text('Zamíchat'),
        ),
      ],
    );
  }
}
