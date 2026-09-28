import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/add_to_playlist_sheet.dart';
import 'queue_panel.dart';

/// Přehled méně častých ovladačů (rychlost, hlasitost, uspávač, fronta) --
/// jeden overflow sheet místo cpaní dalších tlačítek do `NowPlayingScreen`
/// hlavičky, stejně jako to řeší Finamp (`speed_menu.dart`/`output_menu.dart`/
/// `sleep_timer_menu.dart` jsou taky samostatné menu, ne natvrdo v hlavním
/// přehrávači).
Future<void> showPlayerMoreSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _PlayerMoreSheet(),
  );
}

class _PlayerMoreSheet extends ConsumerStatefulWidget {
  const _PlayerMoreSheet();

  @override
  ConsumerState<_PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends ConsumerState<_PlayerMoreSheet> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Jen pro překreslení odpočtu uspávače -- `sleepTimerEndAt` je absolutní
    // čas (viz `AudioPlayerState`), appka ho jinak nikde sekundově netikuje.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(audioPlayerControllerProvider);
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final theme = Theme.of(context);
    final accent = playback.accentColor ?? theme.colorScheme.primary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
        // Scrollovatelné -- s dalšími řádky (normalizace, předvolby rychlosti)
        // by se sheet na nízkém displeji telefonu jinak přetekl.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSpacing.md),
                  decoration:
                      BoxDecoration(color: theme.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Symbols.queue_music_rounded),
                title: const Text('Fronta'),
                subtitle: playback.queueSourceLabel != null ? Text('Přehráváno z ${playback.queueSourceLabel}') : null,
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () {
                  Navigator.of(context).pop();
                  showQueuePanel(context, accentColor: accent);
                },
              ),
              if (playback.nowPlaying != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Symbols.playlist_add_rounded),
                  title: const Text('Přidat do playlistu'),
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(context).pop();
                    showAddToPlaylistSheet(context, recordingId: playback.nowPlaying!.recordingId);
                  },
                ),
              const Divider(),
              const Row(
                children: [
                  Icon(Symbols.speed_rounded),
                  SizedBox(width: AppSpacing.sm),
                  Text('Rychlost přehrávání'),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              // Pevné předvolby místo plynulého slideru (vzor z Finampova
              // `speed_menu.dart`) -- na mobilu se slider na přesnou hodnotu
              // trefuje špatně a mezihodnoty jako 1.1× nikdo nepoužívá.
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final speed in const [0.75, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                      label: Text('${_formatSpeed(speed)}×'),
                      selected: (playback.speed - speed).abs() < 0.01,
                      onSelected: (_) => controller.setSpeed(speed),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  const Icon(Symbols.volume_up_rounded),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Hlasitost: ${(playback.volume * 100).round()} %'),
                ],
              ),
              Slider(value: playback.volume, onChanged: controller.setVolume),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Symbols.graphic_eq_rounded),
                title: const Text('Normalizace hlasitosti'),
                subtitle: const Text('Srovná hlasité a tiché skladby na podobnou úroveň'),
                value: playback.normalizationEnabled,
                onChanged: controller.setNormalizationEnabled,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Uspávač', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              if (playback.sleepTimerEndAt != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Row(
                    children: [
                      Text(_isFading(playback.sleepTimerEndAt!)
                          ? 'Ztlumuje se...'
                          : 'Zbývá ${_formatRemaining(playback.sleepTimerEndAt!)}'),
                      const Spacer(),
                      TextButton(onPressed: controller.cancelSleepTimer, child: const Text('Zrušit')),
                    ],
                  ),
                ),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final minutes in [5, 15, 30, 45, 60])
                    ActionChip(
                      label: Text('$minutes min'),
                      onPressed: () => controller.startSleepTimer(Duration(minutes: minutes)),
                    ),
                  ActionChip(
                    label: const Text('Konec skladby'),
                    onPressed: playback.duration == null
                        ? null
                        : () => controller.startSleepTimer(playback.duration! - playback.position),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSpeed(double speed) => speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : speed.toString();

  bool _isFading(DateTime endAt) {
    final remaining = endAt.difference(DateTime.now());
    return !remaining.isNegative && remaining <= AudioPlayerController.sleepTimerFadeDuration;
  }

  String _formatRemaining(DateTime endAt) {
    final remaining = endAt.difference(DateTime.now());
    if (remaining.isNegative) return '0:00';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
