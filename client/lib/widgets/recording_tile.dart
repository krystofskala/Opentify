import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/availability.dart';
import '../models/recording_model.dart';
import '../state/playback_controller.dart';
import '../state/provisioning_controller.dart';
import 'availability_badge.dart';

/// Řádek jedné nahrávky s akční ikonou vpravo, jejíž chování se odvíjí od
/// živého provisioning stavu (`ProvisioningController`), ne jen od
/// statického `availability` z katalogové odpovědi:
///
///   - `available`        -> ikona přehrání, klik spustí playback.
///   - `provisionable`     -> ikona stažení, klik zavolá `POST /provision`.
///   - probíhá provisioning -> spinner (a `pct` z `job.progress`, pokud přišel).
///   - `FAILED`            -> ikona chyby, klik zkusí provisioning znovu.
///
/// Použito v tracklistu alba (features/release) i v doporučených seznamech
/// na domovské obrazovce (features/home).
class RecordingTile extends ConsumerWidget {
  const RecordingTile({super.key, required this.recording, this.leadingIndex, this.subtitle});

  final RecordingModel recording;
  final int? leadingIndex;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provisioning = ref.watch(provisioningControllerProvider);
    final trackState = provisioning[recording.id];
    final status = trackState?.status;
    final isAvailable = status == 'AVAILABLE' || recording.availability == Availability.available;
    final isInFlight = trackState?.isInFlight ?? false;
    final isFailed = trackState?.isFailed ?? false;

    return ListTile(
      leading: leadingIndex == null
          ? const AvailabilityBadge(availability: Availability.provisionable)
          : SizedBox(
              width: 32,
              child: Text('$leadingIndex', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ),
      title: Text(recording.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle ?? recording.durationLabel),
      trailing: _buildTrailing(context, ref, isAvailable: isAvailable, isInFlight: isInFlight, isFailed: isFailed, pct: trackState?.pct),
    );
  }

  Widget _buildTrailing(
    BuildContext context,
    WidgetRef ref, {
    required bool isAvailable,
    required bool isInFlight,
    required bool isFailed,
    int? pct,
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
        onPressed: () => ref.read(playbackControllerProvider.notifier).play(recording.id),
      );
    }
    return IconButton(
      icon: Icon(isFailed ? Icons.refresh : Icons.download_outlined),
      tooltip: isFailed ? 'Zkusit znovu' : 'Obstarat a přehrát',
      onPressed: () => ref.read(provisioningControllerProvider.notifier).provision(recording.id),
    );
  }
}
