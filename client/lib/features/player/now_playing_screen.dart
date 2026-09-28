import 'package:flutter/physics.dart';
// Flutter má od 3.47 vlastní `RepeatMode` (`RepeatingAnimationBuilder`) --
// skrytý, ať nekoliduje s naším (`AudioPlayerState.repeatMode`).
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/audio_player_controller.dart';
import '../../state/liked_songs_controller.dart';
import '../../state/provisioning_controller.dart';
import '../../theme/accent_color.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/selected_accent.dart';
import '../../theme/shapes.dart';
import '../../widgets/app_background.dart' show AppBackgroundMirror;
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/lyrics_panel.dart';
import '../../widgets/net_image.dart';
import '../../widgets/now_playing_sheet.dart';
import '../../widgets/state_views.dart';
import '../../widgets/wavy_seek_bar.dart';
import 'player_more_sheet.dart';

/// Celoobrazovkový přehrávač -- interaktivní "sheet" nad aktuální stránkou
/// (poloha z `NowPlayingSheetController`: tažení z mini přehrávače nahoru,
/// tažení dolů po horní části/obalu zpět). Pozadí appky pod hustě namrzlým
/// sklem tónovaným barvou skladby, velký obal jako karusel (táhnout do stran
/// = další/předchozí skladba), vlnovkový seek bar, ovládání a text skladby.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> with SingleTickerProviderStateMixin {
  NowPlayingSheetController? _sheet;
  // Tear-off metody je `==` sama se sebou -- `detach` tak pozná svou trasu.
  void _pop() {
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// Posun karuselu obalů v px (0 = aktuální skladba uprostřed).
  late final AnimationController _carousel = AnimationController.unbounded(vsync: this);
  double _carouselWidth = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sheet == null) {
      _sheet = NowPlayingSheetController.of(context)..attach(_pop);
      // Otevřeno bez tažení (klepnutí, hluboký odkaz) -> vysunout.
      WidgetsBinding.instance.addPostFrameCallback((_) => _sheet?.revealIfIdle());
    }
  }

  @override
  void dispose() {
    _sheet?.detach(_pop);
    _carousel.dispose();
    super.dispose();
  }

  // --- tažení dolů = zasunout ---------------------------------------------

  void _onVerticalStart(DragStartDetails _) => _sheet?.dragStart(context);
  void _onVerticalUpdate(DragUpdateDetails d) => _sheet?.dragUpdate(d.delta.dy, MediaQuery.sizeOf(context).height);
  void _onVerticalEnd(DragEndDetails d) =>
      _sheet?.dragEnd(d.velocity.pixelsPerSecond.dy, MediaQuery.sizeOf(context).height);

  // --- karusel obalů ---------------------------------------------------------

  void _onCarouselUpdate(DragUpdateDetails d, AudioPlayerState playback) {
    var next = _carousel.value + d.delta.dx;
    // Na kraji fronty odpor (gumička), ne volný pohyb do prázdna.
    if ((next < 0 && !playback.hasNext) || (next > 0 && playback.previousIndex == null)) {
      next = _carousel.value + d.delta.dx * 0.3;
    }
    _carousel.value = next;
  }

  Future<void> _onCarouselEnd(DragEndDetails d, AudioPlayerState playback) async {
    final v = d.velocity.pixelsPerSecond.dx;
    final dx = _carousel.value;
    final page = _carouselWidth;
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final goNext = playback.hasNext && (dx < -page * 0.28 || v < -700);
    final goPrev = playback.previousIndex != null && (dx > page * 0.28 || v > 700);
    const spring = SpringDescription(mass: 1, stiffness: 420, damping: 38);
    if (goNext || goPrev) {
      final target = goNext ? -page : page;
      await _carousel.animateWith(SpringSimulation(spring, dx, target, v));
      if (!mounted) return;
      if (goNext) {
        await controller.next();
      } else {
        await controller.skipToIndex(playback.previousIndex!);
      }
      _carousel.value = 0;
    } else {
      await _carousel.animateWith(SpringSimulation(spring, dx, 0, v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    final theme = Theme.of(context);
    final targetAccent = playback.accentColor ?? ref.watch(effectiveAccentProvider) ?? theme.colorScheme.primary;
    final sheet = _sheet ?? NowPlayingSheetController.of(context);

    if (nowPlaying == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(message: 'Nic nehraje.'));
    }

    return PopScope(
      canPop: false,
      // Systémové "zpět" = zasunout stejnou animací jako tažení.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) sheet.close();
      },
      child: AnimatedBuilder(
        animation: sheet.position,
        builder: (context, child) {
          final v = sheet.position.value;
          final size = MediaQuery.sizeOf(context);
          // Skleněný panel přetažený přes appku: nahoře vykukuje ~10 px
          // ztmavené appky pod status barem, zaoblené horní rohy.
          final topInset = MediaQuery.paddingOf(context).top + 10;
          final panelHeight = size.height - topInset;
          final panelTop = topInset + (1 - v) * panelHeight;
          const radius = BorderRadius.vertical(top: Radius.circular(Expressive.cornerExtraLarge));
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: 0.4 * v))),
              ),
              Positioned(
                top: panelTop,
                left: 0,
                right: 0,
                height: panelHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, -4)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Živý gradient appky (už v barvě skladby) přesně na
                        // svém místě na obrazovce -- obsah stránky pod panelem
                        // je tím úplně zakrytý, barvy a pohyb prosvítají.
                        Positioned(
                          top: -panelTop,
                          left: 0,
                          width: size.width,
                          height: size.height,
                          child: const AppBackgroundMirror(),
                        ),
                        MediaQuery.removePadding(context: context, removeTop: true, child: child!),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: AnimatedAccent(
          color: targetAccent,
          builder: (context, accent) => _buildSheet(context, playback, accent),
        ),
      ),
    );
  }

  Widget _buildSheet(BuildContext context, AudioPlayerState playback, Color accent) {
    final nowPlaying = playback.nowPlaying!;
    final duration = playback.duration ?? Duration.zero;
    final positionMs =
        playback.position.inMilliseconds.clamp(0, duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds);
    final isWide = MediaQuery.sizeOf(context).width >= 720;

    final provisioningState = ref.watch(provisioningControllerProvider)[nowPlaying.recordingId];
    final isProvisioning = provisioningState?.isInFlight ?? false;
    final provisioningPct = provisioningState?.pct;

    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Sklo panelu nad živým gradientem (ne mléčný závoj): jemné
          // tónování barvou skladby + ztmavení kvůli čitelnosti bílého obsahu
          // (světlý režim víc -- pastelový gradient), vnitřní horní lesk a
          // vlasová zrcadlová hrana nahoře.
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  accent.withValues(alpha: 0.16),
                  Colors.black.withValues(alpha: dark ? 0.22 : 0.34),
                ),
              ),
            ),
          ),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment(0, -0.55),
                  colors: [Color(0x1FFFFFFF), Color(0x00FFFFFF)],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: GlassEdgePainter(
                  shape: glassShape(
                    const BorderRadius.vertical(top: Radius.circular(Expressive.cornerExtraLarge)),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  // Horní část (lišta + obal + název) = úchyt pro tažení dolů.
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: _onVerticalStart,
                      onVerticalDragUpdate: _onVerticalUpdate,
                      onVerticalDragEnd: _onVerticalEnd,
                      child: Column(
                        children: [
                          _grabber(),
                          _header(context, nowPlaying, accent),
                          Expanded(
                            child: Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: isWide ? 480 : double.infinity),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(child: _carouselView(playback)),
                                    const SizedBox(height: 28),
                                    _titleBlock(context, playback, isProvisioning, provisioningState),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: isWide ? 480 : double.infinity),
                    // Ovládání na o stupeň světlejším skle (bez dalšího
                    // rozmazání -- sklo na skle bez dvojitého blur).
                    child: GlassContainer(
                      blur: false,
                      baseFill: false,
                      emphasis: 0.07,
                      borderRadius: BorderRadius.circular(Expressive.cornerExtraLarge),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                      child: _controls(playback, accent, duration, positionMs, isProvisioning, provisioningPct),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grabber() => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Container(
          width: 38,
          height: 5,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(3)),
        ),
      );

  Widget _header(BuildContext context, NowPlayingInfo nowPlaying, Color accent) {
    final isLiked = ref.watch(
      likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(nowPlaying.recordingId) ?? false),
    );
    final sourceLabel = ref.watch(audioPlayerControllerProvider.select((s) => s.queueSourceLabel));
    return Row(
      children: [
        IconButton(
          icon: const Icon(Symbols.keyboard_arrow_down_rounded, color: Colors.white, size: 32),
          tooltip: 'Zasunout',
          onPressed: () => _sheet?.close(),
        ),
        Expanded(
          child: Column(
            children: [
              const Text(
                'PŘEHRÁVÁ SE',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 2),
              ),
              if (sourceLabel != null)
                Text(
                  sourceLabel,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(
            isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
            color: isLiked ? Colors.redAccent : Colors.white,
            size: 24,
          ),
          tooltip: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
          onPressed: () => ref.read(likedSongsControllerProvider.notifier).toggle(nowPlaying.recordingId),
        ),
        IconButton(
          icon: const Icon(Symbols.lyrics_rounded, color: Colors.white, size: 24),
          tooltip: 'Text skladby',
          onPressed: () => showLyricsPanel(context, recordingId: nowPlaying.recordingId, accentColor: accent),
        ),
        IconButton(
          icon: const Icon(Symbols.more_vert_rounded, color: Colors.white, size: 24),
          tooltip: 'Další možnosti',
          onPressed: () => showPlayerMoreSheet(context),
        ),
      ],
    );
  }

  /// Obal jako karusel: předchozí/další skladba vykukují po stranách a
  /// posouvají se s prstem; puštění dokončí pružinou (nebo vrátí zpět).
  Widget _carouselView(AudioPlayerState playback) {
    final prev = playback.previousIndex == null ? null : playback.queue[playback.previousIndex!];
    final next = playback.nextIndex == null ? null : playback.queue[playback.nextIndex!];
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 24.0;
          _carouselWidth = constraints.maxWidth + gap;
          return GestureDetector(
            onHorizontalDragStart: (_) => _carousel.stop(),
            onHorizontalDragUpdate: (d) => _onCarouselUpdate(d, playback),
            onHorizontalDragEnd: (d) => _onCarouselEnd(d, playback),
            child: AnimatedBuilder(
              animation: _carousel,
              builder: (context, _) {
                final dx = _carousel.value;
                final w = _carouselWidth;
                Widget page(NowPlayingInfo info, double offset) {
                  final distance = (offset.abs() / w).clamp(0.0, 1.0);
                  return Transform.translate(
                    offset: Offset(offset, 0),
                    child: Transform.scale(scale: 1 - 0.08 * distance, child: _Artwork(info: info)),
                  );
                }

                return Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    if (prev != null && dx > 0) page(prev, dx - w),
                    if (next != null && dx < 0) page(next, dx + w),
                    page(playback.nowPlaying!, dx),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _titleBlock(
    BuildContext context,
    AudioPlayerState playback,
    bool isProvisioning,
    TrackProvisioningState? provisioningState,
  ) {
    final nowPlaying = playback.nowPlaying!;
    return AnimatedBuilder(
      animation: _carousel,
      builder: (context, child) => Opacity(
        opacity: (1 - (_carousel.value.abs() / _carouselWidth) * 1.4).clamp(0.0, 1.0),
        child: child,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: nowPlaying.releaseId == null
                ? null
                : () {
                    _sheet?.close();
                    context.push('/releases/${nowPlaying.releaseId}?track=${nowPlaying.recordingId}');
                  },
            child: Text(
              nowPlaying.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
            ),
          ),
          if (nowPlaying.artistName != null || nowPlaying.artistId != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: nowPlaying.artistId == null
                  ? null
                  : () {
                      _sheet?.close();
                      context.push('/artists/${nowPlaying.artistId}');
                    },
              child: Text(
                nowPlaying.artistName ?? 'Zobrazit interpreta',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 16,
                  decoration: nowPlaying.artistId != null ? TextDecoration.underline : null,
                  decorationColor: Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
          if (isProvisioning) ...[
            const SizedBox(height: 8),
            Text(
              provisioningState!.statusLabel,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _controls(
    AudioPlayerState playback,
    Color accent,
    Duration duration,
    int positionMs,
    bool isProvisioning,
    int? provisioningPct,
  ) {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    // Ovládání na světlejším skleněném panelu -- bez vlastního rozmazání
    // (leží na už namrzlém skle).
    return GlassContainer(
      blur: false,
      baseFill: false,
      emphasis: GlassTokens.emphasis,
      borderRadius: BorderRadius.circular(28),
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          WavySeekBar(
            progress: duration.inMilliseconds == 0 ? 0 : positionMs / duration.inMilliseconds,
            isPlaying: playback.isPlaying,
            onChangeEnd: duration.inMilliseconds == 0
                ? null
                : (value) => controller.seek(Duration(milliseconds: (value * duration.inMilliseconds).round())),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(playback.position), style: const TextStyle(color: Colors.white70)),
                Text(_formatDuration(duration), style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(Symbols.shuffle_rounded, color: playback.shuffleEnabled ? accent : Colors.white54, size: 22),
                tooltip: 'Náhodné přehrávání',
                onPressed: controller.toggleShuffle,
              ),
              IconButton(
                icon: const Icon(Symbols.skip_previous_rounded, color: Colors.white, size: 34),
                onPressed: playback.hasPrevious || playback.position > const Duration(seconds: 3)
                    ? controller.previous
                    : null,
              ),
              // M3 Expressive: play = "cookie" tvar, pauza = squircle --
              // tvar pružinou morfuje se stavem.
              GlassPressable(
                onPressed: playback.isBuffering ? null : controller.togglePlayPause,
                shape: const CircleBorder(),
                semanticLabel: playback.isPlaying ? 'Pozastavit' : 'Přehrát',
                child: ExpressiveMorph(
                  size: 88,
                  color: Colors.white,
                  shape: playback.isPlaying
                      ? const ExpressiveShape.squircle()
                      : const ExpressiveShape.cookie(lobes: 9, depth: 0.09),
                  child: playback.isBuffering
                      ? (isProvisioning && provisioningPct != null
                          ? SizedBox.square(
                              dimension: 40,
                              child: CircularProgressIndicator(strokeWidth: 3, color: accent, value: provisioningPct / 100),
                            )
                          : ExpressiveLoadingIndicator(size: 40, color: accent))
                      : Icon(
                          playback.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                          size: 44,
                          color: accent,
                        ),
                ),
              ),
              IconButton(
                icon: const Icon(Symbols.skip_next_rounded, color: Colors.white, size: 34),
                onPressed: playback.hasNext ? controller.next : null,
              ),
              IconButton(
                icon: Icon(
                  playback.repeatMode == RepeatMode.one ? Symbols.repeat_one_rounded : Symbols.repeat_rounded,
                  color: playback.repeatMode == RepeatMode.off ? Colors.white54 : accent,
                  size: 22,
                ),
                tooltip: 'Opakování',
                onPressed: controller.cycleRepeatMode,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.info});

  final NowPlayingInfo info;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: AppShapes.of(24),
        shadows: const [BoxShadow(color: Color(0x55000000), blurRadius: 32, offset: Offset(0, 14))],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: AppShapes.of(24)),
        child: info.artworkUrl != null
            ? NetImage(url: info.artworkUrl!)
            : Container(
                color: Colors.white.withValues(alpha: 0.15),
                child: const Icon(Symbols.music_note_rounded, color: Colors.white, size: 96),
              ),
      ),
    );
  }
}
