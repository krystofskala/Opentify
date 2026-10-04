import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
// Flutter má od 3.47 vlastní `RepeatMode` (`RepeatingAnimationBuilder`) --
// skrytý, ať nekoliduje s naším (`AudioPlayerState.repeatMode`).
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../widgets/like_heart.dart';
import '../../state/audio_player_controller.dart';
import '../../state/glass_settings.dart';
import '../../state/provisioning_controller.dart';
import '../../theme/accent_color.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/selected_accent.dart';
import '../../theme/shapes.dart';
import '../../widgets/app_background.dart' show AppBackgroundMirror;
import '../../widgets/glass/expressive_shapes.dart';
import '../../state/artwork_provider.dart';
import '../../state/providers.dart' show catalogRepositoryProvider;
import '../../widgets/glass/glass.dart';
import '../../widgets/glass/liquid_glass.dart';
import '../../widgets/lyrics_panel.dart';
import '../../widgets/media_card.dart' show ArtworkPlaceholder;
import '../../widgets/net_image.dart';
import '../../widgets/now_playing_sheet.dart';
import '../../widgets/state_views.dart';
import '../../widgets/wavy_seek_bar.dart';
import 'player_more_sheet.dart';
import 'queue_panel.dart';
import 'dart:async';
import '../../data/listen_later_repository.dart' show LaterKind;
import '../../state/listen_later_controller.dart';
import '../../state/player_buttons_controller.dart';
import '../../widgets/add_to_playlist_sheet.dart';
import '../../widgets/radio_station.dart';
import '../../widgets/share_sheet.dart';
import '../share/share_card_screen.dart';
import '../../widgets/section_app_bar.dart';
import '../../state/connect_controller.dart';
import '../../widgets/connect_sheet.dart';
import '../../theme/design_tokens.dart';

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

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> with TickerProviderStateMixin {
  NowPlayingSheetController? _sheet;

  /// Otevřený druhý sloupec (PC); `null` = zavřený (výchozí).
  _SidePanel? _side;

  /// Co sloupec ukazuje i během zavírací animace.
  _SidePanel _lastSide = _SidePanel.lyrics;

  /// Telefon: režim textu jako v Apple Music (malý obal nahoře, text
  /// přes střed, ovládání dole) místo sheetu s textem.
  bool _lyricsMode = false;

  /// Přechod obal ↔ text (0 = obal, 1 = text): obal se plynule zmenší do
  /// řádku nahoře, ovládání sjede dolů, text se vynoří -- vše jednou pružinou.
  late final AnimationController _lyricsAnim = AnimationController(vsync: this, duration: Motion.enter.duration);
  late final CurvedAnimation _lyricsCurve =
      CurvedAnimation(parent: _lyricsAnim, curve: Motion.enter, reverseCurve: Motion.enter.flipped);
  double? _titleH;
  double? _controlsH;

  void _setLyrics(bool on, {bool animate = true, bool save = true}) {
    if (on == _lyricsMode) return;
    setState(() => _lyricsMode = on);
    if (animate && !MediaQuery.disableAnimationsOf(context)) {
      on ? _lyricsAnim.forward() : _lyricsAnim.reverse();
    } else {
      _lyricsAnim.value = on ? 1 : 0;
    }
    if (save) ref.read(lyricsModeProvider.notifier).set(on);
  }

  @override
  void initState() {
    super.initState();
    // Uložený přepínač: přehrávač se otevře rovnou v režimu, ve kterém byl
    // naposled (bez animace). Při prvním spuštění se hodnota načítá
    // asynchronně -- proto posluchač, ne jednorázové čtení.
    var initializing = true;
    ref.listenManual<bool>(lyricsModeProvider, (_, on) {
      if (!mounted || on == _lyricsMode) return;
      if (initializing) {
        // setState v initState nejde -- první hodnota rovnou do polí.
        _lyricsMode = on;
        _lyricsAnim.value = on ? 1 : 0;
      } else {
        _setLyrics(on, animate: false, save: false);
      }
    }, fireImmediately: true);
    initializing = false;
  }

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
    _lyricsAnim.dispose();
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
      // Pružina končí pár pixelů od nuly -- dorovnat přesně.
      if (mounted && !_carousel.isAnimating) _carousel.value = 0;
    }
  }

  /// Tlačítka Další/Předchozí posunou obal stejnou animací jako přejetí
  /// prstem (dřív obal jen skokem přeskočil).
  Future<void> _skip({required bool forward}) async {
    final playback = ref.read(audioPlayerControllerProvider);
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final slides =
        forward ? playback.hasNext : playback.previousIndex != null && playback.position <= const Duration(seconds: 3);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!slides || reduce || _carousel.isAnimating) {
      forward ? await controller.next() : await controller.previous();
      return;
    }
    const spring = SpringDescription(mass: 1, stiffness: 420, damping: 38);
    await _carousel
        .animateWith(SpringSimulation(spring, _carousel.value, forward ? -_carouselWidth : _carouselWidth, 0));
    if (!mounted) return;
    forward ? await controller.next() : await controller.previous();
    if (mounted) _carousel.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    // Pozice (5x za vteřinu) přestavuje jen vlnovku a časy (`_SeekRow`),
    // ne celý přehrávač.
    ref.watch(audioPlayerControllerProvider.select(playerChromeKey));
    final playback = ref.read(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    final theme = Theme.of(context);
    final targetAccent = playback.accentColor ?? ref.watch(effectiveAccentProvider) ?? theme.colorScheme.primary;
    final sheet = _sheet ?? NowPlayingSheetController.of(context);

    if (nowPlaying == null) {
      return const Scaffold(appBar: SectionAppBar(''), body: EmptyState(message: 'Nic nehraje.'));
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
          // Během vysouvání (jako Oznamovací centrum v iOS) je panel sklo
          // s lomem nad appkou: obsah pod ním je vidět, s výškou se víc
          // rozmazává a těsně před horní hranou se rozplyne do pozadí
          // přehrávače (`veil`). Úplně nahoře už jen neprůhledné pozadí.
          // "Bez skla": sklo se nekreslí -- panel má plné pozadí hned od
          // začátku vysouvání (jinak prosvítala stránka i lišty pod ním).
          final solid = GlassSettings.solidOf(context);
          final veil = solid ? 1.0 : Curves.easeInCubic.transform(((v - 0.55) / 0.45).clamp(0.0, 1.0));
          final glassy = v < 0.999 && !solid;
          return Stack(
            children: [
              // Ztmavení appky jen NAD panelem -- pod panelem by ho sklo při
              // rychlém pohybu (obyčejné rozmazání) bralo s sebou a oproti
              // lomu (ten ho nevidí) blikalo tmavě/světle.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: panelTop + Expressive.cornerExtraLarge,
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
                    // Stín jen pod neprůhledným panelem -- přes průhledné
                    // sklo by prosvítal jako šedá skvrna.
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35 * veil),
                          blurRadius: 30,
                          offset: const Offset(0, -4)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    // Obsah přehrávače jde zachytit pro sklo s lomem nad ním
                    // (sheet fronty, viz `playerLiquidCapture`).
                    child: LiquidCaptureScope(
                      capture: playerLiquidCapture,
                      child: LiquidSource.page(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Živý gradient appky (už v barvě skladby) přesně na
                            // svém místě na obrazovce -- obsah stránky pod panelem
                            // je tím úplně zakrytý, barvy a pohyb prosvítají.
                            if (glassy)
                              Positioned.fill(
                                child: LiquidCaptureScope(
                                  capture: routeLiquidCapture,
                                  // Čiré sklo (bez tónu): pozadí přehrávače je
                                  // animace a ta musí být vidět čistá.
                                  child: GlassContainer(
                                    liquid: true,
                                    rim: true,
                                    baseFill: false,
                                    borderRadius: radius,
                                    blurSigma: lerpDouble(4, 22, v)!,
                                    fit: StackFit.expand,
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                            if (veil > 0)
                              Positioned(
                                top: -panelTop,
                                left: 0,
                                width: size.width,
                                height: size.height,
                                child: Opacity(opacity: veil, child: const AppBackgroundMirror()),
                              ),
                            MediaQuery.removePadding(context: context, removeTop: true, child: child!),
                          ],
                        ),
                      ),
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

    final provisioningState = ref.watch(provisioningControllerProvider.select((m) => m[nowPlaying.recordingId]));
    final isProvisioning = provisioningState?.isInFlight ?? false;
    final provisioningPct = provisioningState?.pct;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Panel bez tónování (živě: "pozadí velkého přehrávače nemá být
          // tónované vůbec") -- čisté živé pozadí, vrstvu ukazuje jen hrana.
          // Výjimka: světlý režim -- přehrávač má bílé popředí a na světlém
          // pastelovém pozadí by bez ztmavení nebylo čitelné.
          if (!GlassSettings.solidOf(context))
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
                                // Telefon: vlastní rozložení -- desktopové
                                // `player` (karusel, ovládání) ani nestavět.
                                if (!sideColumnFits) {
                                  return _phoneStage(constraints, playback, accent, duration, positionMs,
                                      isProvisioning, provisioningState, provisioningPct);
                                }
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

  /// Telefon: obal/název/ovládání a režim textu jako JEDNA scéna s polohami
  /// spočítanými z rozměrů -- při přepnutí se obal plynule zmenší do rohu
  /// (nebo zpět), ovládání sjede ke spodní hraně, velký název odpluje
  /// a malý se vynoří, text vyjede zespodu (jako v Apple Music). Dřív se
  /// dvě rozložení jen prolnula.
  Widget _phoneStage(
    BoxConstraints constraints,
    AudioPlayerState playback,
    Color accent,
    Duration duration,
    int positionMs,
    bool isProvisioning,
    TrackProvisioningState? provisioningState,
    int? provisioningPct,
  ) {
    final nowPlaying = playback.nowPlaying!;
    final fullW = constraints.maxWidth, h = constraints.maxHeight;
    final w = math.min(fullW, 480.0);
    final x0 = (fullW - w) / 2;
    double interval(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
    return AnimatedBuilder(
      animation: _lyricsCurve,
      builder: (context, _) {
        final t = _lyricsCurve.value;
        final tc = t.clamp(0.0, 1.0);
        final titleH = _titleH ?? 84;
        final ctrlH = _controlsH ?? 230;
        // Obalový režim: obal + název + ovládání jako jedna skupina uprostřed.
        final coverS = math.max(0.0, math.min(w, h - (28 + titleH + 24 + ctrlH)));
        final groupH = coverS + 28 + titleH + 24 + ctrlH;
        final top0 = math.max(0.0, (h - groupH) / 2);
        final big = Rect.fromLTWH(x0 + (w - coverS) / 2, top0, coverS, coverS);
        final small = Rect.fromLTWH(x0, 8, 60, 60);
        final cover = Rect.lerp(big, small, t)!;
        final titleTop = top0 + coverS + 28;
        final ctrlTop = lerpDouble(titleTop + titleH + 24, h - ctrlH, t)!;
        final lyricsIn = interval(tc, 0.3, 1);
        final smallIn = interval(tc, 0.45, 1);
        final bigOut = interval(tc, 0, 0.35);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (tc > 0.01)
              Positioned(
                left: x0,
                width: w,
                top: 80 + (1 - lyricsIn) * 48,
                bottom: ctrlH + 4,
                child: IgnorePointer(
                  ignoring: !_lyricsMode,
                  child: Opacity(
                    opacity: lyricsIn,
                    child: ShaderMask(
                      // Text se nahoře a dole rozplyne (jako v Apple Music).
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
                        stops: [0, 0.06, 0.86, 1],
                      ).createShader(rect),
                      child: LyricsView(recordingId: nowPlaying.recordingId, immersive: true, color: playerFg(context)),
                    ),
                  ),
                ),
              ),
            // Velký název -- odpluje nahoru spolu s obalem a zmizí.
            Positioned(
              left: x0,
              width: w,
              top: lerpDouble(titleTop, titleTop - 60, tc),
              child: IgnorePointer(
                ignoring: _lyricsMode,
                child: Opacity(
                  opacity: 1 - bigOut,
                  child: _MeasureSize(
                    onChange: (size) {
                      if (_titleH != size.height) setState(() => _titleH = size.height);
                    },
                    child: _titleBlock(context, playback, isProvisioning, provisioningState),
                  ),
                ),
              ),
            ),
            // Malý řádek vedle zmenšeného obalu.
            Positioned(
              left: x0 + 74,
              width: w - 74,
              top: 8,
              height: 60,
              child: IgnorePointer(
                ignoring: !_lyricsMode,
                child: Opacity(
                  opacity: smallIn,
                  child: Transform.translate(
                    offset: Offset(0, (1 - smallIn) * 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                nowPlaying.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: playerFg(context), fontSize: AppFontSize.title, fontWeight: FontWeight.w700),
                              ),
                              Text(
                                nowPlaying.artistName ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: playerFg(context).withValues(alpha: 0.7), fontSize: AppFontSize.bodyLarge),
                              ),
                            ],
                          ),
                        ),
                        // Srdíčko je dole v ovládání -- tady přepínač
                        // sledování textu (u téhle skladby).
                        LyricsFollowButton(
                            recordingId: nowPlaying.recordingId, activeColor: accent, color: playerFg(context)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Obal: v klidu karusel (tažení na další/předchozí), při přechodu
            // a v textu jen obrázek (klepnutí vrátí obal).
            Positioned.fromRect(
              rect: cover,
              child: t <= 0.0001 && !_lyricsMode
                  ? _carouselView(playback)
                  : GestureDetector(
                      onTap: () => _setLyrics(false),
                      // Usazený malý obal v textu "žije" s přehráváním.
                      child: t >= 0.999 && _lyricsMode
                          ? _LivingCover(info: nowPlaying, playing: playback.isPlaying)
                          : _Artwork(info: nowPlaying),
                    ),
            ),
            Positioned(
              left: x0,
              width: w,
              top: ctrlTop,
              child: _MeasureSize(
                onChange: (size) {
                  if (_controlsH != size.height) setState(() => _controlsH = size.height);
                },
                child: _controls(playback, accent, duration, positionMs, isProvisioning, provisioningPct),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _grabber() => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Container(
          // Rozměr jako všechny sheety (GlassTokens); sytost vyšší kvůli
          // barevnému pozadí přehrávače.
          width: GlassTokens.grabberSize.width,
          height: GlassTokens.grabberSize.height,
          decoration:
              BoxDecoration(color: playerFg(context).withValues(alpha: 0.45), borderRadius: BorderRadius.circular(3)),
        ),
      );

  Widget _header(BuildContext context, NowPlayingInfo nowPlaying, Color accent) {
    final sourceLabel = ref.watch(audioPlayerControllerProvider.select((s) => s.queueSourceLabel));
    // Obě strany stejně široké, jinak titulek "Přehrává se" není opticky
    // uprostřed (živě nahlášeno). Mobil: 1 + 1 tlačítko, PC: 1 + 2.
    // Srdíčko je všude dole v ovládání -- nahoře jen ⋯ (1 + 1 tlačítko).
    const sideWidth = kMinInteractiveDimension;
    return Row(
      children: [
        SizedBox(
          width: sideWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: Icon(Symbols.keyboard_arrow_down_rounded, color: playerFg(context), size: 32),
              tooltip: 'Zasunout',
              onPressed: () => _sheet?.close(),
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                'PŘEHRÁVÁ SE',
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(color: playerFg(context).withValues(alpha: 0.7), fontSize: AppFontSize.tiny, letterSpacing: 2),
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
                      color: playerFg(context),
                      fontSize: AppFontSize.small,
                      fontWeight: FontWeight.w700,
                      decoration: route == null ? null : TextDecoration.underline,
                      decorationColor: playerFg(context).withValues(alpha: 0.5),
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
              IconButton(
                icon: Icon(Symbols.more_horiz_rounded, color: playerFg(context), size: 24),
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
                Widget page(NowPlayingInfo info, double offset, {bool neighbor = false}) {
                  final distance = (offset.abs() / w).clamp(0.0, 1.0);
                  final art = neighbor ? _NeighborArtwork(info: info) : _Artwork(info: info);
                  return Transform.translate(
                    offset: Offset(offset, 0),
                    child: Transform.scale(scale: 1 - 0.08 * distance, child: art),
                  );
                }

                // Sousední obal jen během tažení: roste s vytažením a po
                // nedokončeném tahu (pružina zpět) zase zmizí -- dřív na
                // širokém okně zůstal stát vedle (pružina se zastaví pár
                // pixelů od nuly). Ve stromu je pořád (průhledný), ať se
                // obrázek načte dopředu.
                final reveal = ((dx.abs() - 2) / (w * 0.12)).clamp(0.0, 1.0);
                return Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    if (prev != null) Opacity(opacity: dx > 0 ? reveal : 0, child: page(prev, dx - w, neighbor: true)),
                    if (next != null) Opacity(opacity: dx < 0 ? reveal : 0, child: page(next, dx + w, neighbor: true)),
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
    // Fronta z playlistu/rádia často album nenese -- dohledat ho, ať název
    // vždy vede na album (živě: odkaz zmizel).
    final releaseId = nowPlaying.releaseId ?? ref.watch(_releaseOfRecording(nowPlaying.recordingId)).valueOrNull;
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
            onTap: releaseId == null
                ? null
                : () => _openAfterClose('/releases/$releaseId?track=${nowPlaying.recordingId}'),
            child: Text(
              nowPlaying.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: playerFg(context), fontSize: AppFontSize.hero, fontWeight: FontWeight.w800),
            ),
          ),
          if (nowPlaying.artistName != null || nowPlaying.artistId != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: nowPlaying.artistId == null ? null : () => _openAfterClose('/artists/${nowPlaying.artistId}'),
              child: Text(
                nowPlaying.artistName ?? 'Zobrazit interpreta',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: playerFg(context).withValues(alpha: 0.78),
                  fontSize: AppFontSize.lead,
                ),
              ),
            ),
          ],
          // Chyba přehrávání -- jako mini přehrávač (dřív tady nebylo nic
          // vidět a tlačítko jen dál zkoušelo play).
          if (playback.error != null) ...[
            const SizedBox(height: 8),
            Text(
              'Nepodařilo se přehrát · ${playback.error}',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: AppFontSize.small),
            ),
          ]
          // Načítání bez známého stavu stahování (stav ještě nedorazil) --
          // jinak jen nekonečný spinner bez vysvětlení (nález vizuálního auditu).
          else if (isProvisioning || (playback.isBuffering && playback.position == Duration.zero)) ...[
            const SizedBox(height: 8),
            Text(
              isProvisioning ? provisioningState!.statusLabel : 'Načítám…',
              textAlign: TextAlign.center,
              style: TextStyle(color: playerFg(context).withValues(alpha: 0.6), fontSize: AppFontSize.small),
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
    final abBadge = _abBadge(playback, accent);
    // Stejné sklo jako mini přehrávač a tab bar (tón, rozmazání, lem)
    // i s lomem -- láme pozadí přehrávače pod sebou.
    // Tón skla podle motivu (ne Profil › Tón skla): ve světlém režimu světlé
    // sklo s tmavými ikonami jako zbytek obsahu -- tmavé sklo s bílými
    // ikonami působilo ve světlém přehrávači cize (živě nahlášeno).
    return GlassSettings.withTone(context, GlassToneMode.auto, LiquidCaptureScope(
      capture: backgroundLiquidCapture,
      child: GlassContainer(
        rim: true,
        liquid: true,
        borderRadius: BorderRadius.circular(Expressive.cornerExtraLarge),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        // Builder: barvy popředí z motivu UVNITŘ skla (tmavé sklo ve světlém
        // režimu dostane tmavý motiv, viz GlassContainer).
        child: Builder(builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Consumer(builder: (context, positionRef, _) {
              final position = positionRef.watch(audioPlayerControllerProvider.select((s) => s.position));
              final ms = duration.inMilliseconds;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  WavySeekBar(
                    activeColor: playerFg(context),
                    thumbColor: playerFg(context),
                    inactiveColor: playerFg(context).withValues(alpha: 0.3),
                    progress: ms == 0 ? 0 : position.inMilliseconds.clamp(0, ms) / ms,
                    isPlaying: playback.isPlaying,
                    onChangeEnd:
                        ms == 0 ? null : (value) => controller.seek(Duration(milliseconds: (value * ms).round())),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position),
                            style: TextStyle(
                                color: playerFg(context).withValues(alpha: 0.7),
                                fontFeatures: const [FontFeature.tabularFigures()])),
                        abBadge,
                        Text(_formatDuration(duration),
                            style: TextStyle(
                                color: playerFg(context).withValues(alpha: 0.7),
                                fontFeatures: const [FontFeature.tabularFigures()])),
                      ],
                    ),
                  ),
                ],
              );
            }),
            // Rovnoměrné rozestupy (živě nahlášeno: nahoře zbytečná mezera,
            // spodní řádek přimáčknutý).
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Předchozí',
                  icon: Icon(Symbols.skip_previous_rounded, color: playerFg(context), size: 34),
                  // Bez předchozí skladby `previous()` přetočí na začátek.
                  onPressed: () => _skip(forward: false),
                ),
                // M3 Expressive: play = "cookie" tvar, pauza = squircle --
                // tvar pružinou morfuje se stavem.
                // Chyba: tlačítko zkusí skladbu znovu (jako mini přehrávač).
                GlassPressable(
                  onPressed: playback.isBuffering
                      ? null
                      : playback.error != null
                          ? controller.retryCurrent
                          : controller.togglePlayPause,
                  shape: const CircleBorder(),
                  semanticLabel: playback.error != null
                      ? 'Zkusit znovu'
                      : playback.isPlaying
                          ? 'Pozastavit'
                          : 'Přehrát',
                  child: ExpressiveMorph(
                    size: 76,
                    // Plocha černá/bílá podle motivu, barva alba jen uvnitř.
                    color: playerFg(context),
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
                        : playback.error != null
                            ? Icon(Symbols.refresh_rounded, size: 40, color: Theme.of(context).colorScheme.error)
                            : Icon(
                            playback.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                            size: 44,
                            color: accent,
                            fill: 1,
                          ),
                  ),
                ),
                IconButton(
                  tooltip: 'Další',
                  icon: Icon(Symbols.skip_next_rounded, color: playerFg(context), size: 34),
                  onPressed: playback.hasNext ? () => _skip(forward: true) : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Text a fronta vždy na dosah pod ovládáním (jako Apple Music);
            // na PC otevírají druhý sloupec, na mobilu sheet.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              // Uživatel si vybírá až 5 tlačítek (⋯ › Upravit tlačítka).
              children: [
                for (final button in ref.watch(playerButtonsProvider))
                  _playerButton(button, accent, playback, controller),
              ],
            ),
          ],
        )),
      ),
    ));
  }

  Widget _playerButton(
    PlayerButton button,
    Color accent,
    AudioPlayerState playback,
    AudioPlayerController controller,
  ) {
    final fg = playerFg(context);
    final idle = fg.withValues(alpha: 0.72);
    Widget plain(String tooltip, IconData icon, VoidCallback? onPressed, {bool active = false}) => IconButton(
          tooltip: tooltip,
          style: IconButton.styleFrom(foregroundColor: active ? accent : idle, fixedSize: const Size.square(44)),
          icon: Icon(icon, size: 22, semanticLabel: tooltip),
          onPressed: onPressed,
        );
    final np = playback.nowPlaying;
    switch (button) {
      case PlayerButton.lyrics:
        return _sideButton(_SidePanel.lyrics, Symbols.lyrics_rounded, 'Text', accent, playback, fg);
      case PlayerButton.queue:
        return _sideButton(_SidePanel.queue, Symbols.queue_music_rounded, 'Fronta', accent, playback, fg);
      case PlayerButton.like:
        return _likeButton(playback, fg);
      case PlayerButton.later:
        final later = np != null &&
            (ref.watch(listenLaterProvider.select((s) => s.valueOrNull?.find(LaterKind.track, np.recordingId))) !=
                null);
        return plain(later ? 'Odebrat z „Na později“' : 'Uložit na později', Symbols.schedule_rounded,
            np == null ? null : () => ref.read(listenLaterProvider.notifier).toggle(context, LaterKind.track, np.recordingId),
            active: later);
      case PlayerButton.radio:
        return plain('Přejít na rádio', Symbols.radio_rounded, np == null
            ? null
            : () {
                final sheet = NowPlayingSheetController.of(context);
                final closed = Completer<bool>();
                goToRadio(context, RadioSeed.track, np.recordingId, openAfter: closed.future, replaceTop: true);
                closed.complete(sheet.slideDown());
              });
      case PlayerButton.share:
        return plain('Sdílet…', Symbols.ios_share_rounded, np == null
            ? null
            : () => showShareSheet(
                  context,
                  title: np.title,
                  artistName: np.artistName,
                  opentifyPath: '/track/${np.recordingId}',
                  external: (kind: 'recordings', id: np.recordingId),
                  asImage: () => openShareCard(context),
                ));
      case PlayerButton.playlist:
        return plain('Přidat do playlistu', Symbols.playlist_add_rounded,
            np == null ? null : () => showAddToPlaylistSheet(context, recordingId: np.recordingId));
      case PlayerButton.devices:
        final others = ref.watch(connectProvider).isNotEmpty;
        return plain('Zařízení', Symbols.devices_rounded, () => showConnectSheet(context), active: others);
      case PlayerButton.shuffle:
      case PlayerButton.repeat:
        break;
    }
    return _shuffleOrRepeat(button, accent, playback, controller);
  }

  Widget _shuffleOrRepeat(
    PlayerButton button,
    Color accent,
    AudioPlayerState playback,
    AudioPlayerController controller,
  ) {
    if (button == PlayerButton.shuffle) {
      return IconButton(
                  tooltip: 'Náhodné přehrávání',
                  style: IconButton.styleFrom(
                    foregroundColor: playback.shuffleEnabled ? accent : playerFg(context).withValues(alpha: 0.72),
                    fixedSize: const Size.square(44),
                  ),
                  icon: const Icon(Symbols.shuffle_rounded, size: 22, semanticLabel: 'Náhodné přehrávání'),
                  onPressed: controller.toggleShuffle,
                );
    }
    return IconButton(
                  tooltip: 'Opakování',
                  style: IconButton.styleFrom(
                    foregroundColor:
                        playback.repeatMode == RepeatMode.off ? playerFg(context).withValues(alpha: 0.72) : accent,
                    fixedSize: const Size.square(44),
                  ),
                  icon: Icon(
                    playback.repeatMode == RepeatMode.one ? Symbols.repeat_one_rounded : Symbols.repeat_rounded,
                    size: 22,
                    semanticLabel: 'Opakování',
                  ),
                  onPressed: controller.cycleRepeatMode,
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
          color: playerFg(context).withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.repeat_rounded, size: 14, color: accent),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: playerFg(context), fontSize: AppFontSize.caption, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            Icon(Symbols.close_rounded, size: 14, color: playerFg(context).withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }

  // `fg` z kontextu UVNITŘ skla panelu (ne z `this.context`).
  Widget _likeButton(AudioPlayerState playback, Color fg) {
    final id = playback.nowPlaying!.recordingId;
    return LikeHeart(recordingId: id, size: 22, color: fg.withValues(alpha: 0.72));
  }

  Widget _sideButton(_SidePanel panel, IconData icon, String label, Color accent, AudioPlayerState playback, Color fg) {
    final wideSide = MediaQuery.sizeOf(context).width >= _sideColumnMinWidth;
    final active = wideSide ? _side == panel : (panel == _SidePanel.lyrics && _lyricsMode);
    // Jen ikona (jako Apple Music); zapnuté = barva skladby, bez podkladu.
    return IconButton(
      tooltip: label,
      style: IconButton.styleFrom(
        foregroundColor: active ? accent : fg.withValues(alpha: 0.72),
        fixedSize: const Size.square(44),
      ),
      icon: Icon(icon, size: 22, fill: active ? 1 : 0, semanticLabel: label),
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
          _setLyrics(!_lyricsMode);
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
          // PC: sloupec s textem/frontou láme pozadí přehrávače.
          child: LiquidCaptureScope(
            capture: backgroundLiquidCapture,
            child: GlassContainer(
              rim: true,
              liquid: true,
              borderRadius: BorderRadius.circular(Expressive.cornerExtraLarge),
              padding: const EdgeInsets.only(top: 8),
              fit: StackFit.expand,
              child: AnimatedSwitcher(
                duration: Motion.state.duration,
                switchInCurve: Motion.state,
                child: _lastSide == _SidePanel.queue
                    ? Column(
                        key: const ValueKey('queue'),
                        children: [
                          SizedBox(
                            height: 40,
                            child: Center(
                              child: Text('FRONTA',
                                  style: TextStyle(color: playerFg(context).withValues(alpha: 0.7), fontSize: AppFontSize.caption, letterSpacing: 2)),
                            ),
                          ),
                          const Expanded(child: QueueView()),
                        ],
                      )
                    : Stack(
                        key: const ValueKey('lyrics'),
                        children: [
                          Positioned.fill(child: LyricsView(recordingId: recordingId)),
                          Positioned(
                              top: 0,
                              right: 8,
                              child: LyricsFollowButton(
                                recordingId: recordingId,
                                color: playerFg(context),
                                activeColor: ref.read(audioPlayerControllerProvider).accentColor,
                              )),
                        ],
                      ),
              ),
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

/// Obal sousední skladby v karuselu -- položka fronty ho často nenese
/// (playlist, rádio), dohledá se přes album / interpreta.
class _NeighborArtwork extends ConsumerWidget {
  const _NeighborArtwork({required this.info});

  final NowPlayingInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var url = info.artworkUrl;
    if (url == null) {
      final releaseId = info.releaseId ?? ref.watch(_releaseOfRecording(info.recordingId)).valueOrNull;
      url = ref.watch(recordingArtworkProvider((releaseId: releaseId, artistId: info.artistId))).valueOrNull;
    }
    return _Artwork(info: info, url: url);
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.info, this.url});

  final NowPlayingInfo info;
  final String? url;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: AppShapes.of(Expressive.cornerExtraLarge),
        shadows: const [BoxShadow(color: Color(0x55000000), blurRadius: 32, offset: Offset(0, 14))],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: AppShapes.of(Expressive.cornerExtraLarge)),
        child: (url ?? info.artworkUrl) != null
            ? NetImage(url: (url ?? info.artworkUrl)!)
            : const ArtworkPlaceholder(icon: Symbols.music_note_rounded, iconSize: 96),
      ),
    );
  }
}

/// Malý obal v režimu textu: když hraje, žije -- pomalu se otáčí a přelévá
/// mezi expresivními tvary (cookie, květ, čtyřlístek...). Při pauze se
/// plynule vrátí do obyčejného zaobleného čtverce.
class _LivingCover extends StatefulWidget {
  const _LivingCover({required this.info, required this.playing});

  final NowPlayingInfo info;
  final bool playing;

  @override
  State<_LivingCover> createState() => _LivingCoverState();
}

class _LivingCoverState extends State<_LivingCover> with TickerProviderStateMixin {
  static const _shapes = [
    ExpressiveShape.cookie(lobes: 9, depth: 0.09),
    ExpressiveShape.cookie(lobes: 5, depth: 0.2),
    ExpressiveShape.cookie(lobes: 4, depth: 0.2),
    ExpressiveShape.cookie(lobes: 7, depth: 0.14),
    ExpressiveShape.cookie(lobes: 12, depth: 0.06),
  ];
  static const _morphSeconds = 3.2;

  // Čas běží jen při přehrávání; `_live` = síla tvaru (0 = čtverec).
  // Hodiny časovačem ~24x/s (jako fáze vlny ve WavySeekBar), ne
  // `repeat()` každým vsyncem -- to drželo celý přehrávač na 60/120 fps.
  late final _SteppedClock _clock = _SteppedClock(
    _morphSeconds * _shapes.length,
    () =>
        mounted &&
        TickerMode.valuesOf(context).enabled &&
        (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed,
  );
  late final AnimationController _live =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600), value: widget.playing ? 1 : 0);

  bool get _reduce => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    // Omezení pohybu čte MediaQuery -- v initState ještě nejde, až po snímku.
    if (widget.playing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.playing && !_reduce) _clock.repeat();
      });
    }
  }

  @override
  void didUpdateWidget(_LivingCover old) {
    super.didUpdateWidget(old);
    if (old.playing == widget.playing) return;
    if (widget.playing) {
      _live.animateTo(1, curve: Curves.easeOutBack);
      if (!_reduce) _clock.repeat();
    } else {
      _live.animateTo(0, curve: Curves.easeOutCubic).whenComplete(() {
        if (mounted && !widget.playing) _clock.stop();
      });
    }
  }

  /// Tvar bez otočení podle (tvar, zaokrouhlené t, velikost) -- otočení je
  /// jen transformace, takže se 160 bodů nepočítá každý snímek znovu.
  final Map<String, Path> _pathCache = {};

  @override
  void dispose() {
    _clock.dispose();
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.info.artworkUrl != null
        ? NetImage(url: widget.info.artworkUrl!)
        : const ArtworkPlaceholder(icon: Symbols.music_note_rounded);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_clock, _live]),
        builder: (context, child) {
          final pos = _clock.value * _shapes.length;
          final i = pos.floor() % _shapes.length;
          // Každý tvar chvíli drží, pak se přelije do dalšího.
          final t = Curves.easeInOutCubic.transform(((pos - pos.floor() - 0.55) / 0.45).clamp(0.0, 1.0));
          return ClipPath(
            clipper: _LivingClipper(
              a: _shapes[i],
              b: _shapes[(i + 1) % _shapes.length],
              // Zaokrouhlené t -> cesta jde znovu použít z keše.
              t: (t * 50).round() / 50,
              spin: _clock.value * 2 * math.pi,
              live: _live.value,
              cache: _pathCache,
            ),
            child: child,
          );
        },
        child: image,
      ),
    );
  }
}

class _LivingClipper extends CustomClipper<Path> {
  const _LivingClipper({
    required this.a,
    required this.b,
    required this.t,
    required this.spin,
    required this.live,
    this.cache,
  });

  final ExpressiveShape a;
  final ExpressiveShape b;
  final double t;
  final double spin;
  final double live;
  final Map<String, Path>? cache;

  @override
  Path getClip(Size size) {
    // Plně živý tvar = jen otočená cesta -- z keše, otočení maticí.
    if (live >= 1 && cache != null) {
      if (cache!.length > 400) cache!.clear();
      final key = '${a.hashCode}:${b.hashCode}:$t:${size.width}x${size.height}';
      final base = cache![key] ??= _build(size, 0, 1);
      final c = size.center(Offset.zero);
      final cs = math.cos(spin), sn = math.sin(spin);
      return base.transform(Float64List.fromList([
        cs, sn, 0, 0, //
        -sn, cs, 0, 0,
        0, 0, 1, 0,
        c.dx - cs * c.dx + sn * c.dy, c.dy - sn * c.dx - cs * c.dy, 0, 1,
      ]));
    }
    return _build(size, spin, live);
  }

  Path _build(Size size, double spin, double live) {
    const steps = 160;
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final path = Path();
    for (var k = 0; k <= steps; k++) {
      final theta = 2 * math.pi * k / steps;
      // Klid: zaoblený čtverec (superelipsa), stejný dojem jako obal jinde.
      final cs = math.cos(theta).abs(), sn = math.sin(theta).abs();
      final rest = 1 / math.pow(math.pow(cs, 3.2) + math.pow(sn, 3.2), 1 / 3.2);
      final local = theta - spin * live;
      final shape = a.radiusAt(local) * (1 - t) + b.radiusAt(local) * t;
      final r = radius * (rest + (shape - rest) * live);
      final p = c + Offset(math.cos(theta), math.sin(theta)) * r;
      k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  bool shouldReclip(_LivingClipper old) =>
      old.t != t || old.spin != spin || old.live != live || old.a != a || old.b != b;
}

/// Hodiny 0..1 s periodou [seconds], posouvané časovačem ~24x za sekundu
/// (vzor: `_SteppedPhase` ve wavy_seek_bar.dart).
class _SteppedClock extends ChangeNotifier {
  _SteppedClock(this.seconds, this._visible);

  final double seconds;
  final bool Function() _visible;
  Timer? _timer;
  double _value = 0;
  DateTime _last = DateTime.now();

  double get value => _value;

  void repeat() {
    if (_timer != null) return;
    _last = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 42), (_) {
      final now = DateTime.now();
      final dt = now.difference(_last).inMicroseconds / 1e6;
      _last = now;
      if (!_visible()) return;
      _value = (_value + dt / seconds) % 1.0;
      notifyListeners();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// Album nahrávky, když ho položka fronty nenese (`GET /catalog/recordings`).
final _releaseOfRecording = FutureProvider.family<String?, String>((ref, recordingId) async {
  try {
    return (await ref.read(catalogRepositoryProvider).getRecording(recordingId)).releaseId;
  } catch (_) {
    return null;
  }
});

/// Popředí přehrávače (text, ikony, vlnovka): bílé v tmavém režimu, tmavé ve
/// světlém -- stejně jako zbytek appky (dřív vždy bílé, na světlém skle
/// zanikalo).
Color playerFg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? Colors.white : Theme.of(context).colorScheme.onSurface;
