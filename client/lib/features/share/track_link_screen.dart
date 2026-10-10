import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/recording_model.dart';
import '../../routing/branches.dart';
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/track_actions.dart' show nowPlayingInfoFor;
import '../../widgets/section_app_bar.dart';

final _sharedTrackProvider =
    FutureProvider.autoDispose.family<({RecordingModel recording, String? cover}), String>((ref, id) async {
  final catalog = ref.watch(catalogRepositoryProvider);
  final recording = await catalog.getRecording(id);
  String? cover;
  if (recording.releaseId != null) {
    try {
      cover = (await catalog.getRelease(recording.releaseId!)).coverImageUrl;
    } catch (_) {}
  }
  return (recording: recording, cover: cover);
});

/// Skladba poslaná přes „Poslat v Opentify" (`/#/track/<id>`): obal, název,
/// Přehrát a Otevřít album. Přehrává se až na klepnutí -- prohlížeč by
/// automatické spuštění zvuku stejně nepovolil.
class TrackLinkScreen extends ConsumerWidget {
  const TrackLinkScreen({super.key, required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final track = ref.watch(_sharedTrackProvider(recordingId));
    return Scaffold(
      appBar: const SectionAppBar('Poslaná skladba'),
      bottomNavigationBar: const ShellBarSpace(),
      body: track.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Skladbu se nepodařilo najít.')),
        data: (data) {
          final r = data.recording;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.xl),
                        child: ArtworkImage(url: data.cover, icon: Symbols.music_note_rounded),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(r.title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    if (r.artistName != null)
                      Text(
                        r.artistName!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    const SizedBox(height: AppSpacing.lg),
                    GlassButton(
                      label: 'Přehrát',
                      icon: Symbols.play_arrow_rounded,
                      style: GlassButtonStyle.prominent,
                      onPressed: () => ref
                          .read(audioPlayerControllerProvider.notifier)
                          .playTrack(nowPlayingInfoFor(r, artworkUrl: data.cover), sourceLabel: 'Poslaná skladba'),
                    ),
                    if (r.releaseId != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      GlassButton(
                        label: 'Otevřít album',
                        icon: Symbols.album_rounded,
                        onPressed: () => context.push('/releases/${r.releaseId}?track=${r.id}'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
