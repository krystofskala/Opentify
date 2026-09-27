import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/recording_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';
import '../../widgets/recording_tile.dart';

final releaseProvider = FutureProvider.autoDispose.family<ReleaseModel, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getRelease(releaseId);
});

final releaseTracksProvider =
    FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getReleaseTracks(releaseId);
});

/// Detail alba: metadata + obal (`GET /catalog/releases/{id}`) a tracklist
/// (`GET /catalog/releases/{id}/tracks`) jako dvě samostatná volání, protože
/// se různě cachují a tracklist může chvíli trvat (MusicBrainz release lookup).
/// Akce na řádku skladby (přehrát/obstarat) řeší `RecordingTile`.
class ReleaseScreen extends ConsumerWidget {
  const ReleaseScreen({super.key, required this.releaseId});

  final String releaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(releaseProvider(releaseId));
    final tracks = ref.watch(releaseTracksProvider(releaseId));

    return Scaffold(
      appBar: AppBar(
        title: release.maybeWhen(data: (r) => Text(r.title), orElse: () => const Text('Album')),
      ),
      body: release.when(
        data: (releaseModel) => _ReleaseBody(release: releaseModel, tracks: tracks),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('Album se nepodařilo načíst: $error')),
      ),
    );
  }
}

class _ReleaseBody extends StatelessWidget {
  const _ReleaseBody({required this.release, required this.tracks});

  final ReleaseModel release;
  final AsyncValue<List<RecordingModel>> tracks;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: release.coverImageUrl != null
                      ? Image.network(release.coverImageUrl!, fit: BoxFit.cover)
                      : Container(
                          color: Theme.of(context).colorScheme.surfaceVariant,
                          child: const Icon(Icons.album, size: 32),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(release.title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      '${release.releaseType.toUpperCase()} · ${release.yearLabel}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        tracks.when(
          data: (recordings) => recordings.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Tracklist se nepodařilo dohledat v MusicBrainz.'),
                )
              : Column(
                  children: [
                    for (final recording in recordings)
                      RecordingTile(recording: recording, leadingIndex: recording.trackNumber),
                  ],
                ),
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, stack) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Tracklist se nepodařilo načíst: $error'),
          ),
        ),
      ],
    );
  }
}
