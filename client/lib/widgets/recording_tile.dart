import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/availability.dart';
import '../models/recording_model.dart';
import '../state/artwork_provider.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import '../state/provisioning_controller.dart';

/// Kartový řádek jedné nahrávky, jehož chování se odvíjí od živého
/// provisioning stavu (`ProvisioningController`), ne jen od statického
/// `availability` z katalogové odpovědi:
///
///   - `available`        -> ikona přehrání, klik spustí playback.
///   - `provisionable`     -> ikona stažení, klik zavolá `POST /provision`.
///   - probíhá provisioning -> spinner (a `pct` z `job.progress`, pokud přišel).
///   - `FAILED`            -> ikona chyby, klik zkusí provisioning znovu.
///
/// Použito v tracklistu alba (features/release) i v doporučených seznamech
/// na domovské obrazovce (features/home).
class RecordingTile extends ConsumerWidget {
  const RecordingTile({
    super.key,
    required this.recording,
    this.leadingIndex,
    this.subtitle,
    this.albumArtUrl,
    this.artistName,
  });

  final RecordingModel recording;
  final int? leadingIndex;
  final String? subtitle;

  /// Volitelný kontext pro `PlayerBar` (Release/Artist obrazovky ho znají,
  /// doporučené seznamy na Home ne -- lišta se bez nich obejde, jen ukáže
  /// méně metadat a šedý placeholder obalu).
  final String? albumArtUrl;
  final String? artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final provisioning = ref.watch(provisioningControllerProvider);
    final trackState = provisioning[recording.id];
    final status = trackState?.status;
    final isAvailable = status == 'AVAILABLE' || recording.availability == Availability.available;
    final isInFlight = trackState?.isInFlight ?? false;
    final isFailed = trackState?.isFailed ?? false;

    // Volající (Release/Artist) obal už zná a pošle ho přímo -- fallback
    // dotaz na `recordingArtworkProvider` (album, jinak interpret) se
    // spouští, jen když ho po ruce nemáme (doporučené seznamy na Home,
    // search výsledky).
    final resolvedArtUrl = albumArtUrl ??
        (recording.releaseId != null || recording.artistId != null
            ? ref.watch(recordingArtworkProvider((releaseId: recording.releaseId, artistId: recording.artistId))).valueOrNull
            : null);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: isAvailable
            ? () => _play(ref, resolvedArtUrl)
            : (isInFlight ? null : () => ref.read(provisioningControllerProvider.notifier).provision(recording.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (leadingIndex != null)
                SizedBox(
                  width: 28,
                  child: Text('$leadingIndex', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                )
              else
                _Thumbnail(artworkUrl: resolvedArtUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(recording.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      subtitle ?? recording.durationLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _buildTrailing(
                ref,
                isAvailable: isAvailable,
                isInFlight: isInFlight,
                isFailed: isFailed,
                pct: trackState?.pct,
                resolvedArtUrl: resolvedArtUrl,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(WidgetRef ref, String? resolvedArtUrl) {
    final streamUrl = ref.read(provisioningRepositoryProvider).streamUrl(recording.id);
    ref.read(audioPlayerControllerProvider.notifier).playTrack(
          NowPlayingInfo(
            recordingId: recording.id,
            title: recording.title,
            artistName: artistName,
            artworkUrl: resolvedArtUrl,
          ),
          streamUrl,
        );
  }

  Widget _buildTrailing(
    WidgetRef ref, {
    required bool isAvailable,
    required bool isInFlight,
    required bool isFailed,
    int? pct,
    required String? resolvedArtUrl,
  }) {
    if (isInFlight) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, value: pct == null ? null : pct / 100),
      );
    }
    if (isAvailable) {
      return IconButton(
        icon: const Icon(Icons.play_circle_fill),
        tooltip: 'Přehrát',
        onPressed: () => _play(ref, resolvedArtUrl),
      );
    }
    return IconButton(
      icon: Icon(isFailed ? Icons.refresh : Icons.download_outlined),
      tooltip: isFailed ? 'Zkusit znovu' : 'Obstarat a přehrát',
      onPressed: () => ref.read(provisioningControllerProvider.notifier).provision(recording.id),
    );
  }
}

/// Zaoblený obal skladby, nebo přechodový placeholder s notovou ikonou, když
/// volající kontext žádný obal nemá (doporučené seznamy na Home -- `Recording`
/// ve schématu žádné pole s obrázkem nenese, viz docs/openapi.yaml).
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.artworkUrl});
  final String? artworkUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 44,
        height: 44,
        child: artworkUrl != null
            ? CachedNetworkImage(
                imageUrl: artworkUrl!,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 250),
                placeholder: (context, url) => Container(color: theme.colorScheme.surfaceContainerHighest),
                errorWidget: (context, url, error) => Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.music_note, size: 18),
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [theme.colorScheme.primaryContainer, theme.colorScheme.surfaceContainerHighest],
                  ),
                ),
                child: const Icon(Icons.music_note, size: 18),
              ),
      ),
    );
  }
}
