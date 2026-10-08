import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'like_heart.dart';
import '../state/audio_player_controller.dart';
import '../state/provisioning_controller.dart';
import '../theme/accent_color.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../theme/selected_accent.dart';
import 'glass/expressive_shapes.dart';
import 'glass_container.dart';
import 'net_image.dart';
import 'now_playing_sheet.dart';
import 'wavy_seek_bar.dart';
import 'connect_sheet.dart';

/// Max. šířka plovoucí spodní skupiny (mini přehrávač, tab bar) na širokém
/// okně -- zarovnaná na střed jako obsahový sloupec detailů.
const kFloatingBarMaxWidth = 760.0;

/// Perzistentní mini přehrávač -- plovoucí kapsle z hustě namrzlého skla
/// tónovaného barvou skladby. Gesta (jako Apple Music):
///   * klepnutí / tažení nahoru -> interaktivně vysune velký přehrávač
///     (`NowPlayingSheetController`, sheet jde přesně za prstem);
///   * tažení do stran -> další/předchozí skladba, obsah jede s prstem a
///     sousední skladba vykukuje z boku, puštění dokončí pružinou.
class PlayerBar extends ConsumerStatefulWidget {
  const PlayerBar({super.key, this.shadow = true});

  /// `false` v `HomeShell` -- lišta leží těsně nad skleněnou navigací, dva
  /// stíny nad sebou by vypadaly jako špinavý pruh.
  final bool shadow;

  @override
  ConsumerState<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends ConsumerState<PlayerBar> with TickerProviderStateMixin {
  late final AnimationController _swipe = AnimationController.unbounded(vsync: this);

  /// Stažení dolů = zavřít přehrávač (lišta jede za prstem a průhlední).
  late final AnimationController _down = AnimationController.unbounded(vsync: this);
  bool _dismissing = false;
  static const _dismissDistance = 150.0;
  static const _autoDismiss = 56.0;
  double _swipeWidth = 1;

  static const _spring = SpringDescription(mass: 1, stiffness: 420, damping: 38);

  @override
  void dispose() {
    _swipe.dispose();
    _down.dispose();
    super.dispose();
  }

  NowPlayingSheetController get _sheet => NowPlayingSheetController.of(context);

  // Jeden rozpoznávač tahu pro celý mini přehrávač se ZÁMKEM SMĚRU: dřív
  // soupeřil vodorovný (přeskočit) se svislým (vytáhnout) a šikmý tah
  // nahoru často přeskočil skladbu (živě nahlášeno). Po `_lockDistance` px
  // se rozhodne podle převládající osy; vodorovně jen jasně vodorovný tah,
  // jinak má přednost vytažení.
  static const _lockDistance = 12.0;
  Offset _panTotal = Offset.zero;
  Axis? _panAxis;

  void _onPanStart(DragStartDetails _) {
    _panTotal = Offset.zero;
    _panAxis = null;
    _dismissing = false;
    _swipe.stop();
    _down.stop();
  }

  void _onPanUpdate(DragUpdateDetails d, AudioPlayerState playback, double screenHeight) {
    switch (_panAxis) {
      case Axis.horizontal:
        _onSwipeUpdate(d.delta.dx, playback);
      case Axis.vertical when _dismissing:
        _down.value = math.max(0, _down.value + d.delta.dy);
        // Dotažení až k okraji displeje nečekat -- dole si tah bere iOS
        // (lišta domů) a gesto zruší. Po dostatečném stažení zavřít hned.
        if (_down.value > _autoDismiss) {
          _dismissing = false;
          _panAxis = null;
          _onDismissEnd(0);
        }
      case Axis.vertical:
        _sheet.dragUpdate(d.delta.dy, screenHeight);
      case null:
        _panTotal += d.delta;
        if (_panTotal.distance < _lockDistance) return;
        if (_panTotal.dx.abs() > _panTotal.dy.abs() * 1.5) {
          _panAxis = Axis.horizontal;
          _onSwipeUpdate(_panTotal.dx, playback);
        } else if (_panTotal.dy > 0) {
          // Dolů = zavřít (nahoru = vytáhnout velký přehrávač).
          _panAxis = Axis.vertical;
          _dismissing = true;
          _down.value = _panTotal.dy;
        } else {
          _panAxis = Axis.vertical;
          _sheet.dragStart(context);
          _sheet.dragUpdate(_panTotal.dy, screenHeight);
        }
    }
  }

  void _onPanEnd(DragEndDetails d, AudioPlayerState playback, double screenHeight) {
    final axis = _panAxis;
    _panAxis = null;
    if (axis == Axis.horizontal) {
      _onSwipeEnd(d.velocity.pixelsPerSecond.dx, playback);
    } else if (axis == Axis.vertical && _dismissing) {
      _dismissing = false;
      _onDismissEnd(d.velocity.pixelsPerSecond.dy);
    } else if (axis == Axis.vertical) {
      _sheet.dragEnd(d.velocity.pixelsPerSecond.dy, screenHeight);
    }
  }

  Future<void> _onDismissEnd(double v) async {
    final y = _down.value;
    // Nízké prahy -- na dotyku Flutter pozná tah až po ~36 px, a víc místa
    // dolů nad lištou domů není (na iPhonu se dřív nedalo zavřít).
    if (y > 24 || v > 350) {
      HapticFeedback.lightImpact();
      await _down.animateWith(SpringSimulation(_spring, y, _dismissDistance, v));
      if (!mounted) return;
      await ref.read(audioPlayerControllerProvider.notifier).dismiss();
      _down.value = 0;
    } else {
      await _down.animateWith(SpringSimulation(_spring, y, 0, v));
    }
  }

  void _onSwipeUpdate(double deltaX, AudioPlayerState playback) {
    var next = _swipe.value + deltaX;
    if ((next < 0 && !playback.hasNext) || (next > 0 && playback.previousIndex == null)) {
      next = _swipe.value + deltaX * 0.3; // gumička na kraji fronty
    }
    _swipe.value = next;
  }

  Future<void> _onSwipeEnd(double v, AudioPlayerState playback) async {
    final dx = _swipe.value;
    final w = _swipeWidth;
    final goNext = playback.hasNext && (dx < -w * 0.3 || v < -650);
    final goPrev = playback.previousIndex != null && (dx > w * 0.3 || v > 650);
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    if (goNext || goPrev) {
      await _swipe.animateWith(SpringSimulation(_spring, dx, goNext ? -w : w, v));
      if (!mounted) return;
      if (goNext) {
        await controller.next();
      } else {
        await controller.skipToIndex(playback.previousIndex!);
      }
      // Sousední skladba je teď aktuální -- na střed bez skoku.
      _swipe.value = 0;
    } else {
      await _swipe.animateWith(SpringSimulation(_spring, dx, 0, v));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Přestavět jen při změně skladby/stavu, ne při každém posunu pozice
    // (ten kreslí jen vlnovka níž ve vlastním `Consumer`).
    ref.watch(audioPlayerControllerProvider.select(playerChromeKey));
    final playback = ref.read(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    // Tady nic nehraje, jinde ano -> "Hraje na <zařízení>" (Opentify Connect).
    if (nowPlaying == null) return const RemotePlayingBar();

    final theme = Theme.of(context);
    // Barva nové skladby ještě není spočítaná -> drží se předchozí (ne
    // okamžik přes `primary`, které se zrovna samo animuje).
    final targetAccent = playback.accentColor ?? ref.watch(effectiveAccentProvider) ?? theme.colorScheme.primary;
    final duration = playback.shownDuration ?? Duration.zero;
    final hasError = playback.error != null;
    final provisioningState = ref.watch(provisioningControllerProvider.select((m) => m[nowPlaying.recordingId]));
    final isProvisioning = provisioningState?.isInFlight ?? false;
    final provisioningPct = provisioningState?.pct;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return AnimatedAccent(
      color: targetAccent,
      builder: (context, accent) {
        // Popředí dle režimu -- na světlém namrzlém skle tmavé, na tmavém
        // bílé (HIG Accessibility: kontrast min. 4.5:1).
        final fg = Theme.of(context).colorScheme.onSurface;
        final bar = Padding(
          // Stejné okraje jako tab bar pod ní (`GlassTokens.floatingMargin`).
          padding: EdgeInsets.fromLTRB(
            GlassTokens.floatingMargin,
            0,
            GlassTokens.floatingMargin,
            8 + MediaQuery.paddingOf(context).bottom,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _sheet.open(context),
            onPanStart: _onPanStart,
            onPanUpdate: (d) => _onPanUpdate(d, playback, screenHeight),
            onPanEnd: (d) => _onPanEnd(d, playback, screenHeight),
            // Zrušené gesto (prst sjel z okna/displeje): vrátit lištu, jinak
            // zůstala viset napůl stažená za navigací.
            onPanCancel: () => _onPanEnd(DragEndDetails(), playback, screenHeight),
            // Stejné sklo jako tab bar pod ní (stejný tón z GlassSettings) --
            // dřív měla každá lišta jiný nádech (živě nahlášeno).
            child: GlassContainer(
              // Stejně kulatá jako tab bar pod ní -- dřív 26 vs. 31 (design audit #11).
              borderRadius: BorderRadius.circular(GlassTokens.tabBarHeight / 2),
              shadow: widget.shadow,
              rim: true,
              liquid: true,
              systemGlass: true,
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Průběh: tažením do strany jde přetáčet i tady (klepnutí
                    // dál rozbalí přehrávač, tažení dolů zavře). Vyšší pás =
                    // větší plocha pro prst, vizuálně stejné místo.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 2, 22, 0),
                      child: SizedBox(
                        height: 26,
                        // Délka z katalogu ještě neznamená načtený zdroj -- při
                        // obstarávání dál ukázat průběh stahování.
                        child: duration.inMilliseconds == 0 || (playback.duration == null && playback.isBuffering)
                            ? (playback.isBuffering
                                ? Center(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        minHeight: 3,
                                        color: fg,
                                        backgroundColor: fg.withValues(alpha: 0.15),
                                        value: isProvisioning && provisioningPct != null ? provisioningPct / 100 : null,
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink())
                            : Consumer(
                                builder: (context, ref, _) {
                                  final position = ref.watch(audioPlayerControllerProvider.select((s) => s.position));
                                  final ms = duration.inMilliseconds;
                                  return WavySeekBar(
                                    progress: position.inMilliseconds.clamp(0, ms) / ms,
                                    isPlaying: playback.isPlaying,
                                    // PC (myš): klik na osu přetočí. Mobil:
                                    // klepnutí dál rozbalí přehrávač.
                                    tapToSeek: MediaQuery.sizeOf(context).width >= 600,
                                    onChangeEnd: (value) => ref
                                        .read(audioPlayerControllerProvider.notifier)
                                        .seek(Duration(milliseconds: (value * ms).round())),
                                    height: 26,
                                    // Čas při ručním posuvu (dlouhé věci se na čáře
                                    // nedají odhadnout; Adam, 8. 10.).
                                    dragLabel: (v) => '${_clock(duration * v)} / ${_clock(duration)}',
                                    strokeWidth: 2.5,
                                    waveAmplitude: 2.5,
                                    activeColor: fg,
                                    inactiveColor: fg.withValues(alpha: 0.3),
                                  );
                                },
                              ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 4, 6, 10),
                      child: Row(
                        children: [
                          Expanded(child: _swipeArea(playback, fg, hasError, isProvisioning, provisioningState)),
                          if (!AudioPlayerController.isSpokenId(nowPlaying.recordingId))
                            LikeHeart(recordingId: nowPlaying.recordingId, size: 22, color: fg)
                          else
                            // Kniha / epizoda: o 30 s zpět i bez otevření přehrávače
                            // (místo srdíčka skladby; převzato z hudby 8. 10.).
                            IconButton(
                              icon: Icon(Symbols.replay_30_rounded, color: fg, size: 24, semanticLabel: 'O 30 s zpět'),
                              tooltip: 'O 30 s zpět',
                              onPressed: () => ref.read(audioPlayerControllerProvider.notifier).seekBy(const Duration(seconds: -30)),
                            ),
                          IconButton(
                            icon: playback.isBuffering
                                ? SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: isProvisioning && provisioningPct != null
                                        ? CircularProgressIndicator(
                                            strokeWidth: 2, color: fg, value: provisioningPct / 100)
                                        : ExpressiveLoadingIndicator(size: 24, color: fg),
                                  )
                                : hasError
                                    ? Icon(Symbols.refresh_rounded,
                                        color: Theme.of(context).colorScheme.error, size: 32, semanticLabel: 'Zkusit znovu')
                                    : Icon(
                                        playback.isPlaying ? Symbols.pause_circle_rounded : Symbols.play_circle_rounded,
                                        color: fg,
                                        size: 38,
                                        semanticLabel: playback.isPlaying ? 'Pozastavit' : 'Přehrát',
                                      ),
                            // Popisek i pro čtečku obrazovky (dřív jen u chyby).
                            tooltip: hasError
                                ? 'Zkusit znovu'
                                : playback.isBuffering
                                    ? 'Načítám…'
                                    : playback.isPlaying
                                        ? 'Pozastavit'
                                        : 'Přehrát',
                            onPressed: playback.isBuffering
                                ? null
                                : hasError
                                    ? () => ref.read(audioPlayerControllerProvider.notifier).retryCurrent()
                                    : () => ref.read(audioPlayerControllerProvider.notifier).togglePlayPause(),
                          ),
                          // Na širokém displeji (desktop) chybí swipe prstem --
                          // přeskočení tlačítkem. Mobil má swipe, tam ne.
                          if (MediaQuery.sizeOf(context).width >= 600)
                            IconButton(
                              icon: Icon(Symbols.skip_next_rounded, color: fg, size: 26, semanticLabel: 'Další skladba'),
                              tooltip: 'Další skladba',
                              onPressed: playback.nextIndex == null
                                  ? null
                                  : () => ref.read(audioPlayerControllerProvider.notifier).next(),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        // Široké okno: kapsle uprostřed s omezenou šířkou (stejně jako tab bar).
        return Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kFloatingBarMaxWidth),
            child: AnimatedBuilder(
              animation: _down,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, _down.value),
                child: Opacity(opacity: (1 - _down.value / _dismissDistance).clamp(0.0, 1.0), child: child),
              ),
              child: bar,
            ),
          ),
        );
      },
    );
  }

  /// Obal + název + interpret -- jede s prstem do stran, sousední skladba
  /// vykukuje z boku (klip na šířku oblasti, tlačítka vpravo stojí).
  Widget _swipeArea(
    AudioPlayerState playback,
    Color fg,
    bool hasError,
    bool isProvisioning,
    TrackProvisioningState? provisioningState,
  ) {
    final prev = playback.previousIndex == null ? null : playback.queue[playback.previousIndex!];
    final next = playback.nextIndex == null ? null : playback.queue[playback.nextIndex!];
    return LayoutBuilder(
      builder: (context, constraints) {
        _swipeWidth = constraints.maxWidth;
        // Tah (přeskočit i vytáhnout) řeší jeden rozpoznávač na celé liště.
        return ClipRect(
          child: AnimatedBuilder(
            animation: _swipe,
            builder: (context, _) {
              final dx = _swipe.value;
              final w = _swipeWidth;
              String? status;
              Color? statusColor;
              if (hasError) {
                status = 'Nepodařilo se přehrát · zkus znovu ↻';
                statusColor = Theme.of(context).colorScheme.error;
              } else if (isProvisioning) {
                status = provisioningState!.statusLabel;
              } else if (playback.isBuffering && playback.position == Duration.zero) {
                status = 'Načítám…';
              }
              return Stack(
                children: [
                  if (prev != null && dx > 0)
                    Transform.translate(offset: Offset(dx - w, 0), child: _TrackInfo(info: prev, fg: fg)),
                  if (next != null && dx < 0)
                    Transform.translate(offset: Offset(dx + w, 0), child: _TrackInfo(info: next, fg: fg)),
                  Transform.translate(
                    offset: Offset(dx, 0),
                    child: _TrackInfo(
                      info: playback.nowPlaying!,
                      fg: fg,
                      status: status,
                      statusColor: statusColor,
                      linkable: true,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.info, required this.fg, this.status, this.statusColor, this.linkable = false});

  final NowPlayingInfo info;
  final Color fg;
  final String? status;
  final Color? statusColor;
  final bool linkable;

  @override
  Widget build(BuildContext context) {
    final subtitle = status ?? info.artistName;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          child: SizedBox(
            width: 44,
            height: 44,
            child: info.artworkUrl != null
                ? NetImage(url: info.artworkUrl!)
                : ColoredBox(
                    color: fg.withValues(alpha: 0.15),
                    child: Icon(Symbols.music_note_rounded, color: fg, size: 20),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontWeight: FontWeight.w700),
              ),
              if (subtitle != null)
                GestureDetector(
                  // Jméno interpreta = odkaz (jen u aktuální skladby, ne u
                  // vykukující sousední); klepnutí jinam rozbalí přehrávač.
                  onTap: linkable && status == null && info.artistId != null
                      ? () => context.push('/artists/${info.artistId}')
                      : null,
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: statusColor ?? fg.withValues(alpha: 0.75), fontSize: AppFontSize.caption),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 1:02:03 / 4:05 (hodiny jen když jsou).
String _clock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, sec = d.inSeconds % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
