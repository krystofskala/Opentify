import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
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
import 'queue_panel.dart';

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

/// Od téhle šířky jsou text/fronta sloupec vedle přehrávače (PC), ne sheet.
const _sideColumnMinWidth = 1100.0;

enum _SidePanel { lyrics, queue }

/// Nahlásí velikost potomka po layoutu (jen při změně).
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize renderObject) => renderObject.onChange = onChange;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(reported));
  }
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> with SingleTickerProviderStateMixin {
  NowPlayingSheetController? _sheet;

  /// Otevřený druhý sloupec (PC); `null` = zavřený (výchozí).
  _SidePanel? _side;

  /// Co sloupec ukazuje i během zavírací animace.
  _SidePanel _lastSide = _SidePanel.lyrics;

  /// Telefon: režim textu jako v Apple Music (malý obal nahoře, text
  /// přes střed, ovládání dole) místo sheetu s textem.
  bool _lyricsMode = false;

  /// Změřená výška skupiny obal + název + ovládání (výška druhého sloupce).
  double? _playerHeight;
  // Tear-off metody je `==` sama se sebou -- `detach` tak pozná svou trasu.
  void _pop() {
    // Jen vlastní trasu -- `pop()` zavře vrchní trasu, a kdyby nad
    // přehrávačem mezitím byla jiná stránka, zavřel by ji (viz
    // `NowPlayingSheetController.close`).
    if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
  }

  /// Odkaz z přehrávače: zasunout a pak trasu přehrávače NAHRADIT cílovou
  /// stránkou (jeden krok navigace, viz `NowPlayingSheetController.slideDown`).
  void _openAfterClose(String location) {
    final router = GoRouter.of(context);
    final sheet = _sheet;
    if (sheet == null) return;
    sheet.slideDown().then((closed) {
      if (closed && mounted) router.pushReplacement(location);
    });
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

  // Jeden rozpoznávač tahu pro celý panel se ZÁMKEM SMĚRU (stejně jako mini
  // přehrávač): dřív soupeřilo svislé zavírání s vodorovným karuselem obalu
  // a šikmý tah dělal to druhé. Po `_lockDistance` px rozhodne převládající
  // osa; vodorovně jen jasně vodorovný tah, který začal NA OBALU (jinde
  // vodorovný tah nic nedělá -- seek bar má vlastní rozpoznávač a vyhraje).
  static const _lockDistance = 12.0;
  final _carouselKey = GlobalKey();
  Offset _panTotal = Offset.zero;
  Axis? _panAxis;
  bool _panOnCover = false;

  void _onPanStart(DragStartDetails d) {
    _panTotal = Offset.zero;
    _panAxis = null;
    final box = _carouselKey.currentContext?.findRenderObject() as RenderBox?;
    _panOnCover = box != null && box.hasSize && (box.localToGlobal(Offset.zero) & box.size).contains(d.globalPosition);
    if (_panOnCover) _carousel.stop();
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final height = MediaQuery.sizeOf(context).height;
    switch (_panAxis) {
      case Axis.horizontal:
        _onCarouselUpdate(d.delta.dx);
      case Axis.vertical:
        _sheet?.dragUpdate(d.delta.dy, height);
      case null:
        _panTotal += d.delta;
        if (_panTotal.distance < _lockDistance) return;
        if (_panOnCover && _panTotal.dx.abs() > _panTotal.dy.abs() * 1.5) {
          _panAxis = Axis.horizontal;
          _onCarouselUpdate(_panTotal.dx);
        } else if (_panTotal.dy.abs() >= _panTotal.dx.abs()) {
          _panAxis = Axis.vertical;
          _sheet?.dragStart(context);
          _sheet?.dragUpdate(_panTotal.dy, height);
        }
    }
  }

  void _onPanEnd(DragEndDetails d) {
    final axis = _panAxis;
    _panAxis = null;
    if (axis == Axis.horizontal) {
      _onCarouselEnd(d.velocity.pixelsPerSecond.dx);
    } else if (axis == Axis.vertical) {
      _sheet?.dragEnd(d.velocity.pixelsPerSecond.dy, MediaQuery.sizeOf(context).height);
    }
  }

  // --- karusel obalů ---------------------------------------------------------

  void _onCarouselUpdate(double deltaX) {
    final playback = ref.read(audioPlayerControllerProvider);
    var next = _carousel.value + deltaX;
    // Na kraji fronty odpor (gumička), ne volný pohyb do prázdna.
    if ((next < 0 && !playback.hasNext) || (next > 0 && playback.previousIndex == null)) {
      next = _carousel.value + deltaX * 0.3;
    }
    _carousel.value = next;
  }

  Future<void> _onCarouselEnd(double v) async {
    final playback = ref.read(audioPlayerControllerProvider);
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
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, -4)),
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
    final sideColumnFits = MediaQuery.sizeOf(context).width >= _sideColumnMinWidth;

    final provisioningState = ref.watch(provisioningControllerProvider)[nowPlaying.recordingId];
    final isProvisioning = provisioningState?.isInFlight ?? false;
    final provisioningPct = provisioningState?.pct;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Panel bez tónování (živě: "pozadí velkého přehrávače nemá být
          // tónované vůbec") -- čisté živé pozadí, vrstvu ukazuje jen hrana.
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
                      onPanStart: _onPanStart,
                      onPanUpdate: _onPanUpdate,
                      onPanEnd: _onPanEnd,
                      child: Column(
                        children: [
                          _grabber(),
                          _header(context, nowPlaying, accent),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final player = ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: isWide ? 480 : double.infinity),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(child: _carouselView(playback)),
                                      const SizedBox(height: 28),
                                      _titleBlock(context, playback, isProvisioning, provisioningState),
                                      const SizedBox(height: 24),
                                      // Ovládání drží u obalu a názvu (jedna
                                      // skupina uprostřed), ne přilepené ke
                                      // spodní hraně (živě nahlášeno). Panel se
                                      // sklem si kreslí `_controls` sám.
                                      _controls(
                                          playback, accent, duration, positionMs, isProvisioning, provisioningPct),
                                    ],
                                  ),
                                );
                                if (!sideColumnFits) {
                                  return AnimatedSwitcher(
                                    duration: Motion.state.duration,
                                    switchInCurve: Motion.state,
                                    child: _lyricsMode
                                        ? _lyricsLayout(context, playback, accent, duration, positionMs,
                                            isProvisioning, provisioningPct)
                                        : Center(key: const ValueKey('cover'), child: player),
                                  );
                                }
                                // PC: text/fronta jako druhý sloupec vedle
                                // obalu a ovládání (stejné světlejší sklo),
                                // jen když ho uživatel otevře.
                                return Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Sloupec má přesně výšku skupiny vlevo
                                      // (obal + název + ovládání).
                                      Flexible(
                                        child: _MeasureSize(
                                          onChange: (size) {
                                            if (_playerHeight != size.height) {
                                              setState(() => _playerHeight = size.height);
                                            }
                                          },
                                          child: player,
                                        ),
                                      ),
                                      _sideColumn(
                                        nowPlaying.recordingId,
                                        _playerHeight ?? math.min(constraints.maxHeight, 780),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
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

  /// Režim textu (telefon): řádek s malým obalem, názvem, interpretem
  /// a srdíčkem, pod ním text přes celou výšku, dole stejné ovládání.
  Widget _lyricsLayout(
    BuildContext context,
    AudioPlayerState playback,
    Color accent,
    Duration duration,
    int positionMs,
    bool isProvisioning,
    int? provisioningPct,
  ) {
    final nowPlaying = playback.nowPlaying!;
    return Column(
      key: const ValueKey('lyrics'),
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            GestureDetector(
              onTap: () => setState(() => _lyricsMode = false),
              child: SizedBox.square(dimension: 60, child: _Artwork(info: nowPlaying)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nowPlaying.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    nowPlaying.artistName ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 15),
                  ),
                ],
              ),
            ),
            _likeButton(playback),
          ],
        ),
        Expanded(
          child: ShaderMask(
            // Text se nahoře a dole rozplyne (jako v Apple Music).
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
              stops: [0, 0.06, 0.86, 1],
            ).createShader(rect),
            child: LyricsView(recordingId: nowPlaying.recordingId, immersive: true, color: Colors.white),
          ),
        ),
        _controls(playback, accent, duration, positionMs, isProvisioning, provisioningPct),
      ],
    );
  }

  Widget _grabber() => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Container(
          width: 38,
          height: 5,
          decoration:
              BoxDecoration(color: Colors.white.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(3)),
        ),
      );

  Widget _header(BuildContext context, NowPlayingInfo nowPlaying, Color accent) {
    final isLiked = ref.watch(
      likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(nowPlaying.recordingId) ?? false),
    );
    final sourceLabel = ref.watch(audioPlayerControllerProvider.select((s) => s.queueSourceLabel));
    // Obě strany stejně široké, jinak titulek "Přehrává se" není opticky
    // uprostřed (živě nahlášeno). Mobil: 1 + 1 tlačítko, PC: 1 + 2.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final sideWidth = (narrow ? 1 : 2) * kMinInteractiveDimension;
    return Row(
      children: [
        SizedBox(
          width: sideWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Symbols.keyboard_arrow_down_rounded, color: Colors.white, size: 32),
              tooltip: 'Zasunout',
              onPressed: () => _sheet?.close(),
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              const Text(
                'PŘEHRÁVÁ SE',
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 2),
              ),
              if (sourceLabel != null)
                Builder(builder: (context) {
                  // Odkud hraje = odkaz na tu stránku (playlist, album...).
                  final route = ref.read(audioPlayerControllerProvider.notifier).queueContext;
                  final label = Text(
                    sourceLabel,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      decoration: route == null ? null : TextDecoration.underline,
                      decorationColor: Colors.white.withValues(alpha: 0.5),
                    ),
                  );
                  if (route == null) return label;
                  return Semantics(
                    link: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openAfterClose(route),
                      child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: label),
                    ),
                  );
                }),
            ],
          ),
        ),
        SizedBox(
          width: sideWidth,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Mobil: srdíčko je v řádku pod ovládáním -- lišta by jinak
              // titulek "Přehrává se" zmáčkla do dvou řádků (živě nahlášeno).
              if (!narrow)
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
                icon: const Icon(Symbols.more_vert_rounded, color: Colors.white, size: 24),
                tooltip: 'Další možnosti',
                onPressed: () => showPlayerMoreSheet(context),
              ),
            ],
          ),
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
          // Tah řeší jeden rozpoznávač se zámkem směru na celém panelu
          // (`_onPan*`); tady jen klíč, podle kterého pozná, že tah začal na obalu.
          return KeyedSubtree(
            key: _carouselKey,
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
                : () => _openAfterClose('/releases/${nowPlaying.releaseId}?track=${nowPlaying.recordingId}'),
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
                  : () => _openAfterClose('/artists/${nowPlaying.artistId}'),
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
    // Stejné sklo jako mini přehrávač a tab bar (tón, rozmazání, lem).
    return GlassContainer(
      rim: true,
      borderRadius: BorderRadius.circular(Expressive.cornerExtraLarge),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
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
                _abBadge(playback, accent),
                Text(_formatDuration(duration), style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          // Rovnoměrné rozestupy (živě nahlášeno: nahoře zbytečná mezera,
          // spodní řádek přimáčknutý).
          const SizedBox(height: 6),
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
                onPressed:
                    playback.hasPrevious || playback.position > const Duration(seconds: 3) ? controller.previous : null,
              ),
              // M3 Expressive: play = "cookie" tvar, pauza = squircle --
              // tvar pružinou morfuje se stavem.
              GlassPressable(
                onPressed: playback.isBuffering ? null : controller.togglePlayPause,
                shape: const CircleBorder(),
                semanticLabel: playback.isPlaying ? 'Pozastavit' : 'Přehrát',
                child: ExpressiveMorph(
                  size: 76,
                  color: Colors.white,
                  shape: playback.isPlaying
                      ? const ExpressiveShape.squircle()
                      : const ExpressiveShape.cookie(lobes: 9, depth: 0.09),
                  child: playback.isBuffering
                      ? (isProvisioning && provisioningPct != null
                          ? SizedBox.square(
                              dimension: 40,
                              child: CircularProgressIndicator(
                                  strokeWidth: 3, color: accent, value: provisioningPct / 100),
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
          const SizedBox(height: 10),
          // Text a fronta vždy na dosah pod ovládáním (jako Apple Music);
          // na PC otevírají druhý sloupec, na mobilu sheet.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _sideButton(_SidePanel.lyrics, Symbols.lyrics_rounded, 'Text', accent, playback),
              _sideButton(_SidePanel.queue, Symbols.queue_music_rounded, 'Fronta', accent, playback),
              // Mobil: srdíčko tady místo horní lišty (tam na něj není místo).
              if (MediaQuery.sizeOf(context).width < 600) _likeButton(playback),
            ],
          ),
        ],
      ),
    );
  }

  /// Štítek běžícího A-B opakování (nastavuje se v menu "⋮"); klepnutí vypne.
  Widget _abBadge(AudioPlayerState playback, Color accent) {
    final ab = ref.watch(abRepeatProvider);
    if (ab == null || ab.recordingId != playback.nowPlaying?.recordingId) return const SizedBox.shrink();
    final label =
        ab.b == null ? 'A ${_formatDuration(ab.a)} → ?' : 'A-B ${_formatDuration(ab.a)}–${_formatDuration(ab.b!)}';
    return GestureDetector(
      onTap: () => ref.read(abRepeatProvider.notifier).state = null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.repeat_rounded, size: 14, color: accent),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Symbols.close_rounded, size: 14, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _likeButton(AudioPlayerState playback) {
    final id = playback.nowPlaying!.recordingId;
    final isLiked = ref.watch(likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(id) ?? false));
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(
        isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
        fill: isLiked ? 1 : 0,
        color: isLiked ? Colors.redAccent : Colors.white70,
        size: 22,
      ),
      tooltip: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
      onPressed: () => ref.read(likedSongsControllerProvider.notifier).toggle(id),
    );
  }

  Widget _sideButton(_SidePanel panel, IconData icon, String label, Color accent, AudioPlayerState playback) {
    final wideSide = MediaQuery.sizeOf(context).width >= _sideColumnMinWidth;
    final active = wideSide ? _side == panel : (panel == _SidePanel.lyrics && _lyricsMode);
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: active ? Colors.white : Colors.white70,
        backgroundColor: active ? Colors.white.withValues(alpha: 0.14) : Colors.transparent,
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(icon, size: 20, fill: active ? 1 : 0),
      label: Text(label),
      onPressed: () {
        if (MediaQuery.sizeOf(context).width >= _sideColumnMinWidth) {
          setState(() {
            if (_side == panel) {
              _side = null;
            } else {
              _side = panel;
              _lastSide = panel;
            }
          });
        } else if (panel == _SidePanel.lyrics) {
          setState(() => _lyricsMode = !_lyricsMode);
        } else {
          showQueuePanel(context, accentColor: accent);
        }
      },
    );
  }

  /// Druhý sloupec (PC): rozjede se do šířky s prolnutím a posunem, obsah
  /// (text/fronta) se mezi sebou prolíná. Zavřený = nulová šířka.
  Widget _sideColumn(String recordingId, double height) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _side == null ? 0 : 1),
      duration: Motion.enter.duration,
      curve: Motion.enter,
      builder: (context, raw, child) {
        final t = raw.clamp(0.0, 1.0);
        if (t == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: t,
            child: Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset((1 - raw) * 48, 0), child: child),
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 40),
        child: SizedBox(
          width: 460,
          height: height,
          child: GlassContainer(
            rim: true,
            borderRadius: BorderRadius.circular(Expressive.cornerExtraLarge),
            padding: const EdgeInsets.only(top: 8),
            fit: StackFit.expand,
            child: AnimatedSwitcher(
              duration: Motion.state.duration,
              switchInCurve: Motion.state,
              child: _lastSide == _SidePanel.queue
                  ? const Column(
                      key: ValueKey('queue'),
                      children: [
                        SizedBox(
                          height: 40,
                          child: Center(
                            child:
                                Text('FRONTA', style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2)),
                          ),
                        ),
                        Expanded(child: QueueView()),
                      ],
                    )
                  : LyricsView(key: const ValueKey('lyrics'), recordingId: recordingId),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    // Nad hodinu h:mm:ss -- dřív 70min skladba ukazovala "10:00".
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      return '${d.inHours}:$minutes:$seconds';
    }
    return '${d.inMinutes}:$seconds';
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
