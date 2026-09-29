import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/share_link.dart';
import '../../state/audio_player_controller.dart';
import '../../widgets/track_actions.dart' show shareWithToast;
import '../../theme/design_tokens.dart';
import '../../widgets/add_to_playlist_sheet.dart';
import 'queue_panel.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../theme/app_theme.dart';

/// Přehled méně častých ovladačů (rychlost, hlasitost, uspávač, fronta) --
/// jeden overflow sheet místo cpaní dalších tlačítek do `NowPlayingScreen`
/// hlavičky, stejně jako to řeší Finamp (`speed_menu.dart`/`output_menu.dart`/
/// `sleep_timer_menu.dart` jsou taky samostatné menu, ne natvrdo v hlavním
/// přehrávači).
Future<void> showPlayerMoreSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
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

    // Stejné hustě namrzlé, skladbou tónované sklo jako přehrávač.
    return GlassContainer.frosted(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
      tint: accent,
      shadow: false,
      // Obsah vždy světlý na barevném skle (jako přehrávač), nezávisle na
      // světlém/tmavém režimu systému.
      child: Theme(
        data: buildAppTheme(seed: accent, brightness: Brightness.dark),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg),
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
                      decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Symbols.queue_music_rounded),
                    title: const Text('Fronta'),
                    subtitle:
                        playback.queueSourceLabel != null ? Text('Přehráváno z ${playback.queueSourceLabel}') : null,
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
                  if (playback.nowPlaying != null) _shareTile(context, playback),
                  if (playback.nowPlaying != null) _abRepeatTile(context, playback),
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
                  GlassSegmentedControl<double>(
                    segments: [
                      for (final speed in _speeds) GlassSegment(value: speed, label: '${_formatSpeed(speed)}×'),
                    ],
                    selected: _speeds.firstWhere((v) => (playback.speed - v).abs() < 0.01, orElse: () => 1.0),
                    onChanged: controller.setSpeed,
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
                  // Přepínač jen v řádku seznamu (HIG Toggles).
                  GlassSwitchRow(
                    leading: const Icon(Symbols.graphic_eq_rounded),
                    title: 'Normalizace hlasitosti',
                    subtitle: 'Srovná hlasité a tiché skladby na podobnou úroveň',
                    value: playback.normalizationEnabled,
                    onChanged: controller.setNormalizationEnabled,
                  ),
                  if (kIsWeb)
                    GlassSwitchRow(
                      leading: const Icon(Symbols.lock_rounded),
                      title: 'Hrát dál na zamčeném displeji',
                      subtitle: 'Fronta jako jeden nepřetržitý stream (pro iPhone). Projeví se od další skladby.',
                      value: controller.radioModeEnabled,
                      onChanged: (v) async {
                        await controller.setRadioMode(v);
                        if (mounted) setState(() {});
                      },
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
                          GlassButton(
                              label: 'Zrušit',
                              style: GlassButtonStyle.plain,
                              compact: true,
                              onPressed: controller.cancelSleepTimer),
                        ],
                      ),
                    ),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final minutes in [5, 15, 30, 45, 60])
                        GlassButton(
                          label: '$minutes min',
                          compact: true,
                          onPressed: () => controller.startSleepTimer(Duration(minutes: minutes)),
                        ),
                      GlassButton(
                        label: 'Konec skladby',
                        compact: true,
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
        ),
      ),
    );
  }

  /// Univerzální odkaz na právě hrající skladbu (song.link) -- načtený hned
  /// při otevření menu, ať sdílení na iPhonu proběhne přímo po klepnutí.
  Widget _shareTile(BuildContext context, AudioPlayerState playback) {
    final ShareTarget target = (kind: 'recordings', id: playback.nowPlaying!.recordingId);
    final link = ref.watch(shareLinkProvider(target));
    final messenger = ScaffoldMessenger.maybeOf(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Symbols.ios_share_rounded),
      title: const Text('Sdílet skladbu'),
      subtitle: const Text('Odkaz, který kamarád otevře v jakékoliv hudební appce'),
      onTap: () {
        final ready = link.valueOrNull;
        Navigator.of(context).pop();
        shareWithToast(ready, messenger, () => ref.read(shareLinkProvider(target).future));
      },
    );
  }

  /// A-B opakování: 1. klepnutí = bod A (aktuální pozice), 2. = bod B a
  /// smyčka běží, 3. = vypnout.
  Widget _abRepeatTile(BuildContext context, AudioPlayerState playback) {
    final ab = ref.watch(abRepeatProvider);
    final id = playback.nowPlaying!.recordingId;
    final active = ab != null && ab.recordingId == id ? ab : null;
    final String subtitle;
    if (active == null) {
      subtitle = 'Klepni pro bod A (${_formatPosition(playback.position)})';
    } else if (active.b == null) {
      subtitle = 'A ${_formatPosition(active.a)} · klepni pro bod B (${_formatPosition(playback.position)})';
    } else {
      subtitle = 'Opakuje ${_formatPosition(active.a)} – ${_formatPosition(active.b!)} · klepni pro vypnutí';
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Symbols.repeat_rounded, fill: active?.b != null ? 1 : 0),
      title: const Text('A-B opakování'),
      subtitle: Text(subtitle),
      trailing: active != null ? const Icon(Symbols.check_rounded) : null,
      onTap: () {
        final notifier = ref.read(abRepeatProvider.notifier);
        final position = playback.position;
        if (active == null) {
          notifier.state = (recordingId: id, a: position, b: null);
        } else if (active.b == null) {
          if (position <= active.a + const Duration(seconds: 1)) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('Bod B musí být až za bodem A.')));
            return;
          }
          notifier.state = (recordingId: id, a: active.a, b: position);
        } else {
          notifier.state = null;
        }
      },
    );
  }

  String _formatPosition(Duration d) => '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

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
