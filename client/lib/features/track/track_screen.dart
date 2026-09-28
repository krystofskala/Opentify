import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/recording_model.dart';
import '../../state/artwork_provider.dart';
import '../../state/audio_player_controller.dart';
import '../../state/liked_songs_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/add_to_playlist_sheet.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/media_card.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_tile.dart';
import '../artist/artist_screen.dart' show discographyProvider;
import '../release/release_screen.dart' show releaseArtistProvider, releaseProvider, releaseTracksProvider;

final recordingProvider = FutureProvider.autoDispose.family<RecordingModel, String>((ref, recordingId) {
  return ref.watch(catalogRepositoryProvider).getRecording(recordingId);
});

/// Samostatná stránka skladby (UX vzor ze Spotube's `pages/track/track.dart`,
/// BSD-4, vlastní implementace) -- dostupná z názvu skladby kdekoliv v appce,
/// nezávisle na tom, co zrovna hraje: hlavička s obalem, proklik na
/// interpreta/album, akce a "zbytek alba" + další vydání interpreta.
class TrackScreen extends ConsumerWidget {
  const TrackScreen({super.key, required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(recordingProvider(recordingId));
    return recording.when(
      data: (r) => _TrackBody(recording: r),
      loading: () => const DetailLoadingScaffold(),
      error: (error, stack) => DetailErrorScaffold(
        message: 'Skladbu se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(recordingProvider(recordingId)),
      ),
    );
  }
}

class _TrackBody extends ConsumerWidget {
  const _TrackBody({required this.recording});

  final RecordingModel recording;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final artwork = ref
        .watch(recordingArtworkProvider((releaseId: recording.releaseId, artistId: recording.artistId)))
        .valueOrNull;
    final release = recording.releaseId == null ? null : ref.watch(releaseProvider(recording.releaseId!)).valueOrNull;
    final artistName = recording.artistName ??
        (recording.artistId == null ? null : ref.watch(releaseArtistProvider(recording.artistId!)).valueOrNull?.name);
    final albumTracks = recording.releaseId == null ? null : ref.watch(releaseTracksProvider(recording.releaseId!));
    final discography = recording.artistId == null ? null : ref.watch(discographyProvider(recording.artistId!));
    final isLiked = ref.watch(likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(recording.id) ?? false));
    final isCurrent = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId == recording.id));
    final isPlaying = isCurrent && ref.watch(audioPlayerControllerProvider.select((s) => s.isPlaying));
    final player = ref.read(audioPlayerControllerProvider.notifier);
    final info = nowPlayingInfoFor(recording, artworkUrl: artwork, artistNameFallback: artistName);

    void toast(String text) =>
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));

    return ScreenAccent(
      imageUrl: artwork,
      builder: (context, accent) => Scaffold(
        bottomNavigationBar: const PlayerBar(),
        body: CustomScrollView(
          slivers: [
            DetailHeroAppBar(
              title: recording.title,
              imageUrl: artwork,
              accent: accent,
              eyebrow: 'Skladba',
              placeholderIcon: Symbols.music_note_rounded,
              subtitle: [
                if (artistName != null)
                  HeroLink(
                    text: artistName,
                    icon: Symbols.person_rounded,
                    onTap: recording.artistId == null ? null : () => context.push('/artists/${recording.artistId}'),
                  ),
                if (recording.releaseId != null)
                  HeroLink(
                    text: release?.title ?? 'Album',
                    icon: Symbols.album_rounded,
                    onTap: () => context.push('/releases/${recording.releaseId}'),
                  ),
                HeroMeta([
                  if (recording.durationMs != null) recording.durationLabel,
                  if (release != null) release.yearLabel,
                ].join(' · ')),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: isCurrent ? () => player.togglePlayPause() : () => player.playTrack(info, sourceLabel: recording.title),
                      icon: Icon(isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                      label: Text(isPlaying ? 'Pozastavit' : 'Přehrát'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        player.playNext(info);
                        toast('Zařazeno jako další');
                      },
                      icon: const Icon(Symbols.playlist_play_rounded),
                      label: const Text('Jako další'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        player.addToQueue(info);
                        toast('Přidáno do fronty');
                      },
                      icon: const Icon(Symbols.queue_music_rounded),
                      label: const Text('Do fronty'),
                    ),
                    IconButton.filledTonal(
                      onPressed: () => ref.read(likedSongsControllerProvider.notifier).toggle(recording.id),
                      tooltip: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
                      icon: Icon(
                        isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
                        fill: isLiked ? 1 : 0,
                        color: isLiked ? Colors.redAccent : null,
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: () => showAddToPlaylistSheet(context, recordingId: recording.id),
                      tooltip: 'Přidat do playlistu',
                      icon: const Icon(Symbols.playlist_add_rounded),
                    ),
                    IconButton.filledTonal(
                      onPressed: () => showTrackActionsSheet(
                        context,
                        recording: recording,
                        artworkUrl: artwork,
                        artistNameFallback: artistName,
                        showDetailLink: false,
                      ),
                      tooltip: 'Další možnosti',
                      icon: const Icon(Symbols.more_horiz_rounded),
                    ),
                  ],
                ),
              ),
            ),
            if (recording.isrc != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Text('ISRC ${recording.isrc}', style: theme.textTheme.bodySmall),
                ),
              ),
            if (albumTracks != null)
              SliverToBoxAdapter(
                child: albumTracks.when(
                  data: (tracks) => tracks.isEmpty
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SectionHeader(
                              release == null ? 'Z alba' : 'Z alba ${release.title}',
                              onSeeAll: () => context.push('/releases/${recording.releaseId}'),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                              child: Column(
                                children: [
                                  for (final t in tracks)
                                    TrackTile(
                                      recording: t,
                                      leadingIndex: t.trackNumber,
                                      albumArtUrl: release?.coverImageUrl ?? artwork,
                                      artistName: artistName,
                                      queueRecordings: tracks,
                                      sourceLabel: release?.title,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                  loading: () => const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.md),
                    child: SkeletonTrackList(count: 4),
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
            if (discography != null)
              SliverToBoxAdapter(
                child: discography.maybeWhen(
                  data: (d) {
                    final others = d.releases.where((r) => r.id != recording.releaseId).toList();
                    if (others.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionHeader(
                          'Více od ${d.artist.name}',
                          onSeeAll: () => context.push('/artists/${d.artist.id}'),
                        ),
                        SizedBox(
                          height: 190,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                            itemCount: others.length,
                            itemBuilder: (context, index) {
                              final rel = others[index];
                              return Padding(
                                padding: const EdgeInsets.only(right: AppSpacing.sm),
                                child: SizedBox(
                                  width: 140,
                                  child: MediaCard(
                                    title: rel.title,
                                    subtitle: rel.yearLabel,
                                    imageUrl: rel.coverImageUrl,
                                    artworkKey: (releaseId: rel.id, artistId: rel.artistId),
                                    onTap: () => context.push('/releases/${rel.id}'),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                  orElse: () => const SizedBox.shrink(),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
          ],
        ),
      ),
    );
  }
}
