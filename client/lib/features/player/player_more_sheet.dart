import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/share_link.dart';
import '../../data/listen_later_repository.dart' show LaterKind;
import '../../state/listen_later_controller.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/add_to_playlist_sheet.dart';
import '../../widgets/now_playing_sheet.dart';
import '../share/share_card_screen.dart';
import '../../widgets/share_sheet.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/lyrics_panel.dart' show LyricsTimingRow, lyricsVisibleProvider;
import '../../widgets/radio_station.dart';
import 'player_buttons_sheet.dart';
import '../../widgets/connect_sheet.dart';
import '../../widgets/report_problem.dart';
import '../../widgets/toast.dart';
import '../../state/liked_songs_controller.dart' show dislikedProvider;
import '../../state/library_scope.dart' show addTrackToLibrary, libraryIdsProvider;
import '../../state/offline_controller.dart';
import '../../state/pip_player_service.dart';

/// Přehled méně častých ovladačů (rychlost, hlasitost, uspávač, fronta) --
/// jeden overflow sheet místo cpaní dalších tlačítek do `NowPlayingScreen`
/// hlavičky, stejně jako to řeší Finamp (`speed_menu.dart`/`output_menu.dart`/
/// `sleep_timer_menu.dart` jsou taky samostatné menu, ne natvrdo v hlavním
/// přehrávači).
Future<void> showPlayerMoreSheet(BuildContext context) {
  return showGlassSheet(
    context,
    builder: (context) => const _PlayerMoreSheet(),
  );
}

class _PlayerMoreSheet extends ConsumerStatefulWidget {
  const _PlayerMoreSheet();

  @override
  ConsumerState<_PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends ConsumerState<_PlayerMoreSheet> {
  @override
  Widget build(BuildContext context) {
    // Jen to, co sheet ukazuje -- celý stav se mění s polohou několikrát za
    // vteřinu a překresloval celý sheet (poloha je v malém Consumeru níž).
    final nowPlaying = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying));
    final accentColor = ref.watch(audioPlayerControllerProvider.select((s) => s.accentColor));
    final speed = ref.watch(audioPlayerControllerProvider.select((s) => s.speed));
    final volume = ref.watch(audioPlayerControllerProvider.select((s) => s.volume));
    final normalization = ref.watch(audioPlayerControllerProvider.select((s) => s.normalizationEnabled));
    final sleepEndAt = ref.watch(audioPlayerControllerProvider.select((s) => s.sleepTimerEndAt));
    final hasDuration = ref.watch(audioPlayerControllerProvider.select((s) => s.duration != null));
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    // Audiokniha: žádné akce skladby (playlist, rádio, knihovna...).
    final song = nowPlaying != null && !AudioPlayerController.isSpokenId(nowPlaying.recordingId);
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;

    // Stejné hustě namrzlé, skladbou tónované sklo jako přehrávač. Nejvýš
    // 85 % výšky -- nahoře musí zůstat vidět přehrávač (klepnutím tam se
    // panel zavře). S dalšími řádky (rádio) jinak přerostl přes celou
    // obrazovku a nešel zavřít (živě nahlášeno).
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: GlassContainer.frosted(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
        tint: accent,
        liquid: true,
        shadow: false,
        // Barvy obsahu podle skla (GlassContainer motiv sám přepne, když je
        // sklo opačného jasu) -- dřív vynuceně tmavý motiv = bílý text na
        // světlém skle / plné ploše "Bez skla".
        child: Builder(
          builder: (context) => SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Úchyt MIMO scroll -- tažení za něj sheet vždy zavře (scroll
                  // by svislé tažení jinak spolkl). Stejný jako u GlassSheet.
                  const SheetGrabber(),
                  const SizedBox(height: AppSpacing.xs),
                  Flexible(
                    // Scrollovatelné -- s dalšími řádky (normalizace, předvolby rychlosti)
                    // by se sheet na nízkém displeji telefonu jinak přetekl.
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Posun časování textu -- jen když je text vidět.
                          if (song)
                            Consumer(
                              builder: (context, ref, _) => ref.watch(lyricsVisibleProvider) > 0
                                  ? LyricsTimingRow(recordingId: nowPlaying.recordingId)
                                  : const SizedBox.shrink(),
                            ),
                          // Fronta je dole v přehrávači jako tlačítko -- tady už ne (audit UI).
                          if (song) const _SectionLabel('Skladba'),
                          if (song)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Symbols.playlist_add_rounded),
                              // Stejné znění jako menu skladby (track_actions.dart).
                              title: const Text('Přidat do playlistu…'),
                              trailing: const Icon(Symbols.chevron_right_rounded),
                              onTap: () {
                                final host = Navigator.of(context).context;
                                Navigator.of(context).pop();
                                showAddToPlaylistSheet(host, recordingId: nowPlaying.recordingId);
                              },
                            ),
                          if (song) _laterTile(context, nowPlaying),
                          if (song) _libraryTile(context, nowPlaying),
                          // Stažení do zařízení i pro epizodu podcastu (stejná Offline knihovna).
                          if (song || (nowPlaying != null && nowPlaying.recordingId.startsWith('pc:')))
                            _offlineTile(context, nowPlaying),
                          if (song)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Symbols.radio_rounded),
                              title: const Text('Přejít na rádio'),
                              subtitle: const Text('Podobná hudba podle téhle skladby'),
                              trailing: const Icon(Symbols.chevron_right_rounded),
                              onTap: () {
                                // Přehrávač zasunout, rádio se otevře pod ním.
                                final sheet = NowPlayingSheetController.of(context);
                                final id = nowPlaying.recordingId;
                                final closed = Completer<bool>();
                                goToRadio(context, RadioSeed.track, id,
                                    openAfter: closed.future, replaceTop: true);
                                Navigator.of(context).pop();
                                closed.complete(sheet.slideDown());
                              },
                            ),
                          // Jediné „Sdílet…" (Poslat v Opentify / odkaz / jako obrázek).
                          if (song) _shareAllTile(context, nowPlaying),
                          if (song) _dislikeTile(context, nowPlaying),
                          const Divider(),
                          const _SectionLabel('Přehrávání'),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Symbols.devices_rounded),
                            title: const Text('Zařízení'),
                            subtitle: const Text('Co hraje jinde, převzít nebo pustit na jiném zařízení'),
                            trailing: const Icon(Symbols.chevron_right_rounded),
                            onTap: () {
                              final host = Navigator.of(context).context;
                              Navigator.of(context).pop();
                              showConnectSheet(host);
                            },
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Symbols.tune_rounded),
                            title: const Text('Upravit tlačítka přehrávače'),
                            subtitle: const Text('Až 5 ikon v řadě pod ovládáním'),
                            trailing: const Icon(Symbols.chevron_right_rounded),
                            onTap: () {
                              final host = Navigator.of(context).context;
                              Navigator.of(context).pop();
                              showPlayerButtonsSheet(host);
                            },
                          ),
                          // Chrome / Edge na počítači: malé okno nad ostatními okny
                          // (Michael, 8. 10.). Jinde se řádek neukáže.
                          if (kIsWeb && nowPlaying != null && ProviderScope.containerOf(context, listen: false).read(pipPlayerProvider).supported)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Symbols.picture_in_picture_alt_rounded),
                              title: const Text('Plovoucí přehrávač'),
                              subtitle: const Text('Malé okno nad ostatními okny'),
                              onTap: () {
                                // Otevřít ještě v gestu klepnutí (prohlížeč jinak okno nedovolí).
                                unawaited(ProviderScope.containerOf(context, listen: false).read(pipPlayerProvider).open());
                                Navigator.of(context).pop();
                              },
                            ),
                          // Poslouchá polohu jen tenhle řádek, ne celý sheet.
                          if (nowPlaying != null)
                            Consumer(
                              builder: (context, ref, _) => _abRepeatTile(
                                context,
                                ref,
                                nowPlaying.recordingId,
                                ref.watch(audioPlayerControllerProvider.select((s) => s.position)),
                              ),
                            ),
                          // Jen skladba -- u knihy / epizody volalo /library/tracks/sp:…
                          // a skončilo 404 (audit 8. 10.).
                          if (song)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Symbols.sync_problem_rounded),
                              title: const Text('Nahlásit špatné audio – stáhnout správné'),
                              subtitle: const Text('Jiná verze nebo píseň'),
                              onTap: () {
                                final np = nowPlaying;
                                final container = ProviderScope.containerOf(context, listen: false);
                                final messenger = ScaffoldMessenger.maybeOf(context);
                                Navigator.of(context).pop();
                                reportWrongAudio(container, messenger, recordingId: np.recordingId, title: np.title);
                              },
                            ),
                          if (nowPlaying?.releaseId != null)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Symbols.hide_image_rounded),
                              title: const Text('Nahlásit špatný obal alba'),
                              onTap: () {
                                final releaseId = nowPlaying!.releaseId!;
                                final container = ProviderScope.containerOf(context, listen: false);
                                final messenger = ScaffoldMessenger.maybeOf(context);
                                Navigator.of(context).pop();
                                reportWrongCover(container, messenger, releaseId: releaseId);
                              },
                            ),
                          // Oddělit od A-B řádku -- jinak vypadala jako jeho součást.
                          const SizedBox(height: AppSpacing.sm),
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
                            selected: _speeds.firstWhere((v) => (speed - v).abs() < 0.01, orElse: () => 1.0),
                            onChanged: controller.setSpeed,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Row(
                            children: [
                              const Icon(Symbols.volume_up_rounded),
                              const SizedBox(width: AppSpacing.sm),
                              Text('Hlasitost: ${(volume * 100).round()} %'),
                            ],
                          ),
                          Slider(value: volume, onChanged: controller.setVolume),
                          // Přepínač jen v řádku seznamu (HIG Toggles).
                          GlassSwitchRow(
                            leading: const Icon(Symbols.graphic_eq_rounded),
                            title: 'Normalizace hlasitosti',
                            subtitle: 'Srovná hlasité a tiché skladby na podobnou úroveň',
                            value: normalization,
                            onChanged: controller.setNormalizationEnabled,
                          ),
                          if (kIsWeb)
                            GlassSwitchRow(
                              leading: const Icon(Symbols.lock_rounded),
                              title: 'Hrát dál na zamčeném displeji',
                              subtitle:
                                  'Fronta jako jeden nepřetržitý stream (pro iPhone). Projeví se od další skladby.',
                              value: controller.radioModeEnabled,
                              onChanged: (v) async {
                                await controller.setRadioMode(v);
                                if (mounted) setState(() {});
                              },
                            ),
                          const SizedBox(height: AppSpacing.sm),
                          Text('Uspávač', style: theme.textTheme.titleSmall),
                          const SizedBox(height: AppSpacing.xs),
                          if (sleepEndAt != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                              child: Row(
                                children: [
                                  // Sekundový tik jen tady a jen když uspávač běží.
                                  _SleepCountdown(endAt: sleepEndAt),
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
                              // Kniha / epizoda: konec kapitoly (m4b = jeden soubor
                              // na celou knihu); hudba: konec skladby. Obojí podle
                              // skutečného času (rychlost přehrávání).
                              GlassButton(
                                label: song ? 'Konec skladby' : 'Konec kapitoly',
                                compact: true,
                                onPressed: !hasDuration
                                    ? null
                                    : () {
                                        final left = controller.untilChapterEnd();
                                        if (left != null) controller.startSleepTimer(left);
                                      },
                              ),
                            ],
                          ),
                          // Nevratné (zastaví hudbu, vyprázdní frontu) -- až úplně dole
                          // a červeně, ne mezi neškodnými položkami.
                          if (nowPlaying != null) const Divider(),
                          if (nowPlaying != null)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Symbols.close_rounded, color: Theme.of(context).colorScheme.error),
                              title: Text('Zavřít přehrávač', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                              subtitle: const Text('Zastaví hudbu a vyprázdní frontu'),
                              onTap: () {
                                // Nejdřív zasunout velký přehrávač, pak ukončit -- jinak by
                                // na chvíli ukázal prázdné "Nic nehraje".
                                final sheet = NowPlayingSheetController.of(context);
                                final player = ref.read(audioPlayerControllerProvider.notifier);
                                Navigator.of(context).pop();
                                sheet.close();
                                Future.delayed(const Duration(milliseconds: 450), player.dismiss);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "Poslechnout později" pro právě hrající skladbu (přepínač).
  Widget _laterTile(BuildContext context, NowPlayingInfo np) {
    final id = np.recordingId;
    final isLater = ref.watch(listenLaterProvider.select((s) => s.valueOrNull?.find(LaterKind.track, id) != null));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(isLater ? Symbols.event_busy_rounded : Symbols.schedule_rounded),
      title: Text(isLater ? 'Odebrat z „Na později“' : 'Uložit na později'),
      onTap: () {
        final host = Navigator.of(context).context;
        Navigator.of(context).pop();
        ref.read(listenLaterProvider.notifier).toggle(host, LaterKind.track, id);
      },
    );
  }

  /// "Přidat do knihovny" -- jen když tam skladba ještě není (jako menu skladby).
  Widget _libraryTile(BuildContext context, NowPlayingInfo np) {
    final inLibrary = ref.watch(libraryIdsProvider.select((s) => s.valueOrNull?.contains(np.recordingId) ?? true));
    if (inLibrary) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Symbols.library_add_rounded),
      title: const Text('Přidat do knihovny'),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop();
        try {
          await addTrackToLibrary(ref, np.recordingId);
          showToast(messenger, 'Přidáno do knihovny');
        } catch (_) {
          showToast(messenger, 'Nepodařilo se přidat do knihovny');
        }
      },
    );
  }

  /// Stáhnout do zařízení / smazat ze zařízení (stejně jako menu skladby).
  Widget _offlineTile(BuildContext context, NowPlayingInfo np) {
    final offlineState = ref.watch(offlineControllerProvider);
    final isOffline = offlineState.tracks.containsKey(np.recordingId);
    final pending = offlineState.pending.containsKey(np.recordingId);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(isOffline
          ? Symbols.mobile_off_rounded
          : (pending ? Symbols.downloading_rounded : Symbols.download_for_offline_rounded)),
      title: Text(isOffline ? 'Smazat ze zařízení' : (pending ? 'Stahuje se do zařízení…' : 'Stáhnout do zařízení')),
      onTap: () {
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop();
        final offline = ref.read(offlineControllerProvider.notifier);
        if (isOffline) {
          offline.remove(np.recordingId);
          showToast(messenger, 'Smazáno ze zařízení');
        } else if (!pending) {
          offline.add([np]);
          showToast(messenger, 'Stahuje se do zařízení');
        }
      },
    );
  }

  /// "Nelíbí se mi" -- přepínač jako v menu skladby.
  Widget _dislikeTile(BuildContext context, NowPlayingInfo np) {
    final isDisliked = ref.watch(dislikedProvider.select((d) => d.contains(np.recordingId)));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(isDisliked ? Symbols.heart_check_rounded : Symbols.heart_broken_rounded),
      title: Text(isDisliked ? 'Zrušit „Nelíbí se mi“' : 'Nelíbí se mi'),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop();
        final ok = await ref.read(dislikedProvider.notifier).toggle(np.recordingId);
        if (ok) showToast(messenger, isDisliked ? 'Zrušeno: Nelíbí se mi' : 'Označeno: Nelíbí se mi');
      },
    );
  }

  Widget _shareAllTile(BuildContext context, NowPlayingInfo np) {
    final ShareTarget target = (kind: 'recordings', id: np.recordingId);
    ref.watch(shareLinkProvider(target)); // načíst dopředu (Safari)
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Symbols.ios_share_rounded),
      title: const Text('Sdílet…'),
      subtitle: const Text('Poslat v Opentify, odkaz pro jiné aplikace, jako obrázek'),
      onTap: () {
        final nav = Navigator.of(context);
        final host = nav.context;
        nav.pop();
        showShareSheet(
          host,
          title: np.title,
          artistName: np.artistName,
          opentifyPath: '/track/${np.recordingId}',
          external: target,
          asImage: () => openShareCard(host),
        );
      },
    );
  }

  /// A-B opakování: 1. klepnutí = bod A (aktuální pozice), 2. = bod B a
  /// smyčka běží, 3. = vypnout.
  Widget _abRepeatTile(BuildContext context, WidgetRef ref, String id, Duration position) {
    final ab = ref.watch(abRepeatProvider);
    final active = ab != null && ab.recordingId == id ? ab : null;
    final String subtitle;
    if (active == null) {
      subtitle = 'Klepni pro bod A (${_formatPosition(position)})';
    } else if (active.b == null) {
      subtitle = 'A ${_formatPosition(active.a)} · klepni pro bod B (${_formatPosition(position)})';
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
        if (active == null) {
          notifier.state = (recordingId: id, a: position, b: null);
        } else if (active.b == null) {
          if (position <= active.a + const Duration(seconds: 1)) {
            toast(context, 'Bod B musí být až za bodem A.');
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

  // Česky desetinná čárka: 1×, 1,25×, 1,5×.
  String _formatSpeed(double speed) =>
      (speed == speed.roundToDouble() ? speed.toStringAsFixed(0) : speed.toString()).replaceAll('.', ',');

}

/// Odpočet uspávače -- `sleepTimerEndAt` je absolutní čas, appka ho jinak
/// sekundově netikuje. Časovač žije jen s tímhle widgetem, tedy jen když
/// uspávač běží (dřív tikal celý sheet pořád).
class _SleepCountdown extends StatefulWidget {
  const _SleepCountdown({required this.endAt});

  final DateTime endAt;

  @override
  State<_SleepCountdown> createState() => _SleepCountdownState();
}

class _SleepCountdownState extends State<_SleepCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  bool get _isFading {
    final remaining = widget.endAt.difference(DateTime.now());
    return !remaining.isNegative && remaining <= AudioPlayerController.sleepTimerFadeDuration;
  }

  String get _remaining {
    final remaining = widget.endAt.difference(DateTime.now());
    if (remaining.isNegative) return '0:00';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => Text(_isFading ? 'Ztišuje se…' : 'Zbývá $_remaining');
}

/// Nadpis sekce v menu přehrávače (Skladba / Přehrávání).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: AppSpacing.xxs),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}
