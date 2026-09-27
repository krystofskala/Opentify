import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/artist_model.dart';
import '../../models/recording_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/recording_tile.dart';

final releaseProvider = FutureProvider.autoDispose.family<ReleaseModel, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getRelease(releaseId);
});

final releaseTracksProvider =
    FutureProvider.autoDispose.family<List<RecordingModel>, String>((ref, releaseId) {
  return ref.watch(catalogRepositoryProvider).getReleaseTracks(releaseId);
});

/// Jméno interpreta pro `PlayerBar` (Release má jen `artistId`) -- samostatné
/// volání, ne součást `releaseProvider`, protože `ArtistModel` se jinde
/// stejně už cachuje přes stejný provider (viz `ArtistScreen`).
final releaseArtistProvider = FutureProvider.autoDispose.family<ArtistModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getArtist(artistId);
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
      // Datový stav má vlastní `SliverAppBar` (viz `_ReleaseBody`) s obalem
      // na pozadí -- loading/error zůstávají bez něj bez zpětného tlačítka,
      // proto ho tady dodá tenhle vnější Scaffold.
      appBar: release.hasValue ? null : AppBar(),
      bottomNavigationBar: const PlayerBar(),
      body: release.when(
        data: (releaseModel) => _ReleaseBody(release: releaseModel, tracks: tracks),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('Album se nepodařilo načíst: $error')),
      ),
    );
  }
}

class _ReleaseBody extends ConsumerWidget {
  const _ReleaseBody({required this.release, required this.tracks});

  final ReleaseModel release;
  final AsyncValue<List<RecordingModel>> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final artistName = ref.watch(releaseArtistProvider(release.artistId)).maybeWhen(
          data: (artist) => artist.name,
          orElse: () => null,
        );

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 280,
          pinned: true,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (release.coverImageUrl != null)
                  CachedNetworkImage(imageUrl: release.coverImageUrl!, fit: BoxFit.cover)
                else
                  Container(color: theme.colorScheme.primaryContainer),
                // Rozostřená verze obalu na pozadí + skleněná vrstva -- "hero"
                // efekt v duchu Liquid Glass, obal zůstává jen jemně čitelný.
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Container(color: Colors.black.withValues(alpha: 0.35)),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: GlassContainer(
                      borderRadius: BorderRadius.circular(20),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 84,
                              height: 84,
                              child: release.coverImageUrl != null
                                  ? CachedNetworkImage(
                                      imageUrl: release.coverImageUrl!,
                                      fit: BoxFit.cover,
                                      fadeInDuration: const Duration(milliseconds: 250),
                                    )
                                  : Container(
                                      color: Colors.white.withValues(alpha: 0.15),
                                      child: const Icon(Icons.album, size: 32, color: Colors.white),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  release.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                                ),
                                const SizedBox(height: 4),
                                if (artistName != null)
                                  Text(artistName, style: TextStyle(color: Colors.white.withValues(alpha: 0.85))),
                                Text(
                                  '${release.releaseType.toUpperCase()} · ${release.yearLabel}',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        tracks.when(
          data: (recordings) => recordings.isEmpty
              ? const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Tracklist se nepodařilo dohledat v MusicBrainz.'),
                  ),
                )
              : SliverPadding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  sliver: SliverList.builder(
                    itemCount: recordings.length,
                    itemBuilder: (context, index) => RecordingTile(
                      recording: recordings[index],
                      leadingIndex: recordings[index].trackNumber,
                      albumArtUrl: release.coverImageUrl,
                      artistName: artistName,
                    ),
                  ),
                ),
          loading: () => const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (error, stack) => SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Tracklist se nepodařilo načíst: $error'),
            ),
          ),
        ),
      ],
    );
  }
}
