import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/radio_mode.dart' show shouldUseRadioStream;
import '../../core/share_image.dart';
import '../../state/audio_player_controller.dart';
import '../../data/wrapped_repository.dart';
import '../../state/artwork_provider.dart';
import '../../state/providers.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/mix_artwork.dart';
import '../../widgets/state_views.dart';
import 'wrapped_hub_screen.dart' show WrappedCountdown;
import '../../theme/design_tokens.dart';

/// "Tisíce" úzkou nezlomitelnou mezerou: 34 698.
String wrappedNumber(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String _plural(int n, String one, String few, String many) => n == 1
    ? one
    : n >= 2 && n <= 4
        ? few
        : many;

const _monthShort = ['led', 'úno', 'bře', 'dub', 'kvě', 'čvn', 'čvc', 'srp', 'zář', 'říj', 'lis', 'pro'];

/// Wrapped jako příběh: obrazovky 9:16 přes celý displej, klepnutí vpravo/
/// vlevo = další/předchozí, samy se posouvají (podržením se zastaví). Každou
/// jde sdílet jako obrázek 1080×1920 -- vyrenderuje se předem, hned jak
/// doběhne její animace (Safari pustí sdílení jen přímo z klepnutí).
class WrappedStoryScreen extends ConsumerWidget {
  const WrappedStoryScreen({super.key, required this.period});

  final String period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(wrappedStatsProvider(period));
    return Scaffold(
      backgroundColor: Colors.black,
      body: stats.when(
        data: (s) => s.locked ? _Locked(stats: s) : _Story(stats: s),
        loading: () => const _Loading(),
        error: (e, _) => ErrorState(
          message: 'Wrapped se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(wrappedStatsProvider(period)),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const MixBackground(style: MixArtStyle.mood, hue: 262, seed: 'wrapped-loading'),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                  width: 28, height: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
              const SizedBox(height: 16),
              Text('Počítám tvůj rok v hudbě…', style: _text(18, FontWeight.w700)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Locked extends StatelessWidget {
  const _Locked({required this.stats});
  final WrappedStats stats;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const MixBackground(style: MixArtStyle.year, hue: 40, seed: 'wrapped-locked'),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  tooltip: 'Zavřít',
                  onPressed: () => context.pop(),
                  icon: const Icon(Symbols.close_rounded, color: Colors.white, semanticLabel: 'Zavřít'),
                ),
                const Spacer(),
                const Icon(Symbols.lock_rounded, color: Colors.white, size: 40),
                const SizedBox(height: 12),
                Text(stats.isDecade ? 'Tvoje dekáda' : 'Tvůj rok ${stats.label}', style: _text(40, FontWeight.w900)),
                const SizedBox(height: 8),
                if (stats.unlockAt != null)
                  WrappedCountdown(unlockAt: stats.unlockAt!, style: _text(20, FontWeight.w600)),
                const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

TextStyle _text(double size, FontWeight weight, {double opacity = 1, double height = 1.1}) => TextStyle(
      color: Colors.white.withValues(alpha: opacity),
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: size > 40 ? -size * 0.02 : 0,
      shadows: const [Shadow(blurRadius: 12, color: Colors.black38)],
    );

/// Jedna obrazovka: pozadí + obsah (obsah dostává `active`, aby animace
/// běžely, až je obrazovka vidět).
class _Slide {
  const _Slide({required this.style, required this.hue, required this.build, this.trackId});

  final MixArtStyle style;
  final double hue;
  final Widget Function(bool active) build;

  /// Skladba, jejíž úryvek hraje pod obrazovkou (`null` = hraje dál předchozí).
  final String? trackId;
}

class _Story extends ConsumerStatefulWidget {
  const _Story({required this.stats});
  final WrappedStats stats;

  @override
  ConsumerState<_Story> createState() => _StoryState();
}

class _StoryState extends ConsumerState<_Story> with SingleTickerProviderStateMixin {
  static const _slideDuration = Duration(seconds: 8);
  static const _renderDelay = Duration(milliseconds: 2400);

  late final List<_Slide> _slides = _buildSlides(widget.stats);
  late final List<GlobalKey> _keys = [for (final _ in _slides) GlobalKey()];
  final _page = PageController();
  late final AnimationController _progress = AnimationController(vsync: this, duration: _slideDuration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _go(_index + 1);
    });
  final Map<int, Uint8List> _rendered = {};
  Timer? _renderTimer;
  int _index = 0;
  bool _sharing = false;

  // --- Hudba pod obrazovkami (vlastní přehrávače, hlavní se pozastaví) ---
  // Dva přehrávače střídavě -- nový úryvek se pomalu zesiluje, zatímco starý
  // doznívá (prolnutí). iOS hlasitost webu měnit nedovolí a každý <audio>
  // musí zvlášť odemknout klepnutím -- tam jen jeden přehrávač a střih.
  static const _crossfade = Duration(milliseconds: 2500);
  static const _tailFade = Duration(milliseconds: 2500);
  static const _snippetLength = Duration(seconds: 30);
  late final bool _canFade = !shouldUseRadioStream();
  late final List<AudioPlayer> _players = [AudioPlayer(), if (_canFade) AudioPlayer()];
  int _activePlayer = 0;
  AudioPlayer get _audio => _players[_activePlayer];
  final Map<AudioPlayer, Timer> _fades = {};
  StreamSubscription<Duration>? _tailWatch;
  bool _tailFading = false;
  late final AudioPlayerController _mainPlayer = ref.read(audioPlayerControllerProvider.notifier);
  late final WrappedRepository _repo = ref.read(wrappedRepositoryProvider);
  final Map<String, Future<({String url, Duration start})?>> _snippets = {};
  bool _mainWasPlaying = false;

  /// iOS pustí zvuk až po klepnutí -- do té doby se úryvek jen připraví.
  bool _audioUnlocked = false;
  bool _muted = false;
  String? _currentTrack;
  int _audioToken = 0;

  @override
  void initState() {
    super.initState();
    // Adresy všech úryvků hned -- přepnutí karty pak nečeká na server.
    for (final slide in _slides) {
      final id = slide.trackId;
      if (id != null) _snippets[id] ??= _repo.snippet(id);
    }
    _scheduleRender();
    // I skladba, co se teprve načítá (`isPlaying` false) -- jinak se po
    // načtení rozehrála přes úryvky příběhu.
    unawaited(_mainPlayer.pauseIfPlaying().then((was) {
      if (was) _mainWasPlaying = true;
    }));
    // Na PC projde autoplay (stránka otevřená klepnutím); iOS ho odmítne a
    // zvuk se odemkne prvním klepnutím do příběhu.
    _audioUnlocked = true;
    _startSlide(0);
  }

  /// Karta se rozběhne (časovač, animace), až úryvek opravdu hraje --
  /// obraz a hudba synchronně. Bez hudby (ztlumeno, iOS ještě nepovolil
  /// zvuk, úryvek není) nejvýš po 3 s.
  Future<void> _startSlide(int index) async {
    _progress
      ..stop()
      ..value = 0;
    // Počkat na skutečný zvuk (první úryvek se ještě načítá -- dřív 3 s a
    // hudba pak naskočila až ve třetině první karty); zablokované
    // přehrávání (iOS před klepnutím) se nečeká.
    await _playSlideAudio(index).timeout(const Duration(seconds: 10), onTimeout: () {});
    if (!mounted || _index != index) return;
    if (index < _slides.length - 1 && !_progress.isAnimating) _progress.forward();
    _preloadAfter(index);
  }

  @override
  void dispose() {
    _renderTimer?.cancel();
    for (final t in _fades.values) {
      t.cancel();
    }
    _tailWatch?.cancel();
    for (final p in _players) {
      p.dispose();
    }
    _progress.dispose();
    _page.dispose();
    if (_mainWasPlaying) unawaited(_mainPlayer.resumeIfPaused());
    super.dispose();
  }

  void _close() {
    // Hlavní přehrávač obnovit ještě v obsluze klepnutí (iOS).
    for (final p in _players) {
      unawaited(p.pause());
    }
    if (_mainWasPlaying) {
      _mainWasPlaying = false;
      unawaited(_mainPlayer.resumeIfPaused());
    }
    context.pop();
  }

  void _go(int index) {
    if (index < 0 || index >= _slides.length) {
      if (index >= _slides.length) _progress.stop();
      return;
    }
    _page.animateToPage(index, duration: const Duration(milliseconds: 650), curve: Curves.easeInOutCubic);
  }

  void _onTap(TapUpDetails d, double frameW) {
    if (!_audioUnlocked && !_muted) {
      // První klepnutí odemkne zvuk (iOS) -- play() musí být přímo tady.
      _audioUnlocked = true;
      unawaited(_audio.play().catchError((_) {}));
    }
    _go(d.localPosition.dx < frameW * 0.3 ? _index - 1 : _index + 1);
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    if (_muted) {
      for (final p in _players) {
        unawaited(p.pause());
      }
    } else {
      _audioUnlocked = true;
      unawaited(_audio.play().catchError((_) {}));
    }
  }

  void _onPage(int index) {
    setState(() => _index = index);
    _scheduleRender();
    unawaited(_startSlide(index));
  }

  String? _trackFor(int index) {
    for (var i = index; i >= 0; i--) {
      final id = _slides[i].trackId;
      if (id != null) return id;
    }
    return null;
  }

  // Úryvek další karty připravený na volném přehrávači (jen s prolnutím --
  // iOS má jediný přehrávač).
  String? _preloadedTrack;
  AudioPlayer? _preloadedPlayer;

  Future<void> _preloadAfter(int index) async {
    if (!_canFade || index + 1 >= _slides.length) return;
    final trackId = _trackFor(index + 1);
    if (trackId == null || trackId == _currentTrack || trackId == _preloadedTrack) return;
    final snippet = await (_snippets[trackId] ??= _repo.snippet(trackId));
    if (!mounted || snippet == null || trackId == _currentTrack) return;
    final idle = _players[1 - _activePlayer];
    try {
      await idle.setVolume(0);
      await idle.setUrl(snippet.url, initialPosition: snippet.start);
      _preloadedTrack = trackId;
      _preloadedPlayer = idle;
    } catch (_) {}
  }

  /// Plynulá změna hlasitosti jednoho přehrávače (ease-in-out, ~30 kroků/s).
  Future<void> _fadeTo(AudioPlayer player, double target, Duration duration) {
    _fades.remove(player)?.cancel();
    final start = player.volume;
    final steps = math.max(1, duration.inMilliseconds ~/ 33);
    var step = 0;
    final done = Completer<void>();
    _fades[player] = Timer.periodic(duration ~/ steps, (timer) {
      step++;
      // Prolnutí se stejnou výkonovou křivkou (sin/cos): součet hlasitostí
      // obou úryvků neklesne ani nenaskočí -- lineární přechod zněl tvrdě.
      final x = step / steps;
      final t = target > start ? math.sin(x * math.pi / 2) : 1 - math.cos(x * math.pi / 2);
      unawaited(player.setVolume(start + (target - start) * t));
      if (step >= steps) {
        timer.cancel();
        _fades.remove(player);
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  /// Před koncem úryvku (Deezer ukázka má 30 s) hudbu plynule ztlumit, ať
  /// neutne.
  void _watchTail(AudioPlayer player, Duration start) {
    _tailWatch?.cancel();
    _tailFading = false;
    _tailWatch = player.positionStream.listen((position) {
      // Úryvek = nejvýš 30 s (i u stažené skladby, která by jinak hrála celá).
      final full = player.duration;
      final end = start + _snippetLength;
      final limit = full == null || full > end ? end : full;
      if (_tailFading) return;
      final left = limit - position;
      if (!player.playing) return;
      if (_canFade && left <= _tailFade) {
        _tailFading = true;
        final fade = left > Duration.zero ? left : const Duration(milliseconds: 300);
        unawaited(_fadeTo(player, 0, fade).then((_) => player.pause()));
      } else if (!_canFade && left <= Duration.zero) {
        _tailFading = true;
        unawaited(player.pause()); // iOS: hlasitost nejde -- jen zastavit na konci
      }
    });
  }

  Future<void> _playSlideAudio(int index) async {
    final trackId = _trackFor(index);
    if (trackId == null || trackId == _currentTrack) return;
    _currentTrack = trackId;
    final token = ++_audioToken;
    final snippet = await (_snippets[trackId] ??= _repo.snippet(trackId));
    if (!mounted || token != _audioToken || snippet == null) return;

    final previous = _audio;
    // S prolnutím připravit úryvek na druhém přehrávači; bez něj (iOS) nejdřív
    // krátce dotlumit (hlasitost stejně nejde, tak aspoň pauza) a přepnout.
    final next = _canFade ? _players[1 - _activePlayer] : previous;
    if (!_canFade && previous.playing) await previous.pause();
    final ready = _preloadedTrack == trackId && _preloadedPlayer == next;
    _preloadedTrack = null;
    _preloadedPlayer = null;
    if (!ready) {
      try {
        await next.setVolume(0);
        await next.setUrl(snippet.url, initialPosition: snippet.start);
      } catch (_) {
        return;
      }
    }
    if (!mounted || token != _audioToken) return;
    _activePlayer = _players.indexOf(next);
    if (_canFade && previous != next && previous.playing) {
      unawaited(_fadeTo(previous, 0, _crossfade).then((_) {
        if (_audio != previous) previous.pause();
      }));
    }
    if (_muted || !_audioUnlocked) return;
    if (!_canFade) await next.setVolume(1);
    unawaited(next.play().catchError((_) {
      // Autoplay odmítnut (iOS) -- odemkne se prvním klepnutím.
      _audioUnlocked = false;
    }));
    if (_canFade) unawaited(_fadeTo(next, 1, _crossfade));
    _watchTail(next, snippet.start);
    // Hotovo, až zvuk opravdu běží (pozice se hýbe) -- pak se pustí obraz.
    // Odmítnuté přehrávání (`_audioUnlocked` zpět na false) nečekat.
    final started = next.positionStream
        .firstWhere((p) => next.playing && p > snippet.start + const Duration(milliseconds: 80))
        .then((_) {});
    final blocked = Stream<void>.periodic(const Duration(milliseconds: 150))
        .firstWhere((_) => !_audioUnlocked || !mounted || token != _audioToken);
    try {
      await Future.any([started, blocked]).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  void _scheduleRender() {
    _renderTimer?.cancel();
    final index = _index;
    if (_rendered.containsKey(index)) return;
    _renderTimer = Timer(_renderDelay, () async {
      final png = await _capture(index);
      if (png != null && mounted) _rendered[index] = png;
    });
  }

  Future<Uint8List?> _capture(int index) async {
    final boundary = _keys[index].currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) return null;
    try {
      final image = await boundary.toImage(pixelRatio: 1080 / boundary.size.width);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    final name = 'opentify-wrapped-${widget.stats.id}-${_index + 1}.png';
    final text =
        widget.stats.isDecade ? 'Moje hudební dekáda ${widget.stats.label}' : 'Můj rok v hudbě ${widget.stats.label}';
    final ready = _rendered[_index];
    if (ready != null) {
      // Synchronně z klepnutí -- jinak Safari sdílení odmítne.
      unawaited(shareImage(ready, fileName: name, text: text));
      return;
    }
    setState(() => _sharing = true);
    final png = await _capture(_index);
    if (mounted) setState(() => _sharing = false);
    if (png != null) await shareImage(png, fileName: name, text: text);
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final last = _index == _slides.length - 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Na PC uprostřed jako telefon, na telefonu přes celou obrazovku.
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final w = math.min(maxW, maxH * 9 / 16);
        final phone = maxW < 600;
        final frameW = phone ? maxW : w;
        final frameH = phone ? maxH : w * 16 / 9;
        return Center(
          child: SizedBox(
            width: frameW,
            height: frameH,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(phone ? 0 : 24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _onTap(d, frameW),
                    onLongPressStart: (_) => _progress.stop(),
                    onLongPressEnd: (_) {
                      if (!last) _progress.forward();
                    },
                    child: PageView.builder(
                      controller: _page,
                      onPageChanged: _onPage,
                      itemCount: _slides.length,
                      // Přechod "kostkou" jako Instagram stories: obrazovky se
                      // otáčejí kolem společné hrany, odvrácená strana tmavne.
                      itemBuilder: (context, i) => AnimatedBuilder(
                        animation: _page,
                        builder: (context, child) {
                          var page = _index.toDouble();
                          if (_page.hasClients && _page.position.haveDimensions) page = _page.page ?? page;
                          final delta = (i - page).clamp(-1.0, 1.0);
                          return Transform(
                            alignment: delta > 0 ? Alignment.centerLeft : Alignment.centerRight,
                            transform: Matrix4.identity()
                              ..setEntry(3, 2, 0.0012)
                              ..rotateY(-delta * math.pi / 2),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                child!,
                                if (delta != 0)
                                  IgnorePointer(
                                    child: ColoredBox(color: Colors.black.withValues(alpha: delta.abs() * 0.6)),
                                  ),
                              ],
                            ),
                          );
                        },
                        // Sdílený obrázek = jen tahle vrstva (bez otočení a ztmavení).
                        child: RepaintBoundary(
                          key: _keys[i],
                          child: _SlideFrame(slide: _slides[i], active: i == _index, stats: stats),
                        ),
                      ),
                    ),
                  ),
                  // Ovládání (není součástí sdíleného obrázku).
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                      child: Column(
                        children: [
                          _ProgressBars(count: _slides.length, index: _index, progress: _progress),
                          Row(
                            children: [
                              Text(
                                stats.isDecade ? 'Tvoje dekáda' : 'Wrapped ${stats.label}',
                                style: _text(14, FontWeight.w700, opacity: 0.9),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: _muted ? 'Zapnout zvuk' : 'Ztlumit',
                                onPressed: _toggleMute,
                                icon: Icon(
                                  _muted ? Symbols.volume_off_rounded : Symbols.volume_up_rounded,
                                  color: Colors.white,
                                  semanticLabel: _muted ? 'Zapnout zvuk' : 'Ztlumit',
                                ),
                              ),
                              IconButton(
                                tooltip: 'Zavřít',
                                onPressed: _close,
                                icon: const Icon(Symbols.close_rounded, color: Colors.white, semanticLabel: 'Zavřít'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Row(
                          children: [
                            if (last)
                              for (final p in stats.playlists.take(1))
                                Expanded(
                                  child: _PillButton(
                                    icon: Symbols.play_arrow_rounded,
                                    label: 'Otevřít playlist',
                                    onPressed: () => context.push('/playlists/${p.id}'),
                                  ),
                                )
                            else
                              const Spacer(),
                            const SizedBox(width: 10),
                            _PillButton(
                              icon: Symbols.ios_share_rounded,
                              label: _sharing ? 'Připravuji…' : 'Sdílet',
                              onPressed: _share,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: AppFontSize.bodyLarge),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }
}

class _ProgressBars extends StatelessWidget {
  const _ProgressBars({required this.count, required this.index, required this.progress});
  final int count;
  final int index;
  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 3,
                  child: i == index
                      ? AnimatedBuilder(
                          animation: progress,
                          builder: (_, __) => LinearProgressIndicator(
                            value: progress.value,
                            backgroundColor: Colors.white24,
                            color: Colors.white,
                          ),
                        )
                      : ColoredBox(color: i < index ? Colors.white : Colors.white24),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Pozadí + obsah + nenápadná značka dole (je vidět i na sdíleném obrázku).
class _SlideFrame extends StatelessWidget {
  const _SlideFrame({required this.slide, required this.active, required this.stats});
  final _Slide slide;
  final bool active;
  final WrappedStats stats;

  @override
  Widget build(BuildContext context) {
    // Obsah i značka mimo Dynamic Island a pruh domovského indikátoru.
    final safe = MediaQuery.paddingOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        MixBackground(style: slide.style, hue: slide.hue, seed: 'wrapped:${stats.id}:${slide.hue}'),
        // Ztmavení pro čitelnost textu.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x55000000), Color(0x22000000), Color(0x88000000)],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, math.max(84, safe.top + 64), 26, math.max(90, safe.bottom + 64)),
          child: slide.build(active),
        ),
        Positioned(
          left: 26,
          bottom: 30 + safe.bottom,
          child: Text(
            stats.isDecade ? 'OPENTIFY · DEKÁDA ${stats.label}' : 'OPENTIFY · WRAPPED ${stats.label}',
            style: _text(11, FontWeight.w800, opacity: 0.7).copyWith(letterSpacing: 1.4),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Animace
// ---------------------------------------------------------------------------

/// Prvek najede zespodu a zprůhlední se, `order` = pořadí (zpoždění).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.active, required this.order, required this.child});
  final bool active;
  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = order * 160;
    final total = 600 + delay;
    return TweenAnimationBuilder<double>(
      key: ValueKey(active),
      tween: Tween(begin: 0, end: active ? 1 : 0),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 30), child: child),
      ),
      child: child,
    );
  }
}

class _CountUp extends StatelessWidget {
  const _CountUp({required this.value, required this.active, required this.style});
  final int value;
  final bool active;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(active),
      tween: Tween(begin: 0, end: active ? value.toDouble() : 0),
      duration: const Duration(milliseconds: 1700),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(wrappedNumber(v.round()), style: style),
    );
  }
}

// ---------------------------------------------------------------------------
// Obrázky (interpret / skladba), s dohledáním, když server obal nemá
// ---------------------------------------------------------------------------

class _Art extends ConsumerWidget {
  const _Art({this.url, this.releaseId, this.artistId, required this.size, this.circle = false});
  final String? url;
  final String? releaseId;
  final String? artistId;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = url ??
        (releaseId != null || artistId != null
            ? ref.watch(recordingArtworkProvider((releaseId: releaseId, artistId: artistId))).valueOrNull
            : null);
    final image = SizedBox(
      width: size,
      height: size,
      child: ArtworkImage(
        url: resolved,
        icon: circle ? Symbols.person_rounded : Symbols.album_rounded,
        iconSize: size * 0.35,
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(size * 0.06),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 24, offset: Offset(0, 10))],
      ),
      child:
          circle ? ClipOval(child: image) : ClipRRect(borderRadius: BorderRadius.circular(size * 0.06), child: image),
    );
  }
}

// ---------------------------------------------------------------------------
// Obrazovky
// ---------------------------------------------------------------------------

List<_Slide> _buildSlides(WrappedStats s) {
  final baseHue = s.isDecade ? 36.0 : ((int.tryParse(s.label) ?? 0) * 47 + 20) % 360.0;
  double hue(int shift) => (baseHue + shift) % 360;
  final days = (s.totalMinutes / 1440).floor();
  String? t(int i) => i < s.topTracks.length ? s.topTracks[i].id : null;
  String? a(int i) => i < s.topArtists.length ? s.topArtists[i].trackId : null;
  final slides = <_Slide>[
    _Slide(
      style: MixArtStyle.year,
      hue: hue(0),
      trackId: t(0),
      build: (a) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          _Reveal(
            active: a,
            order: 0,
            child: Text(s.isDecade ? 'TVOJE HUDEBNÍ DEKÁDA' : 'TVŮJ ROK V HUDBĚ',
                style: _text(15, FontWeight.w800, opacity: 0.85)),
          ),
          const SizedBox(height: 10),
          _Reveal(
            active: a,
            order: 1,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(s.label, style: _text(s.isDecade ? 72 : 110, FontWeight.w900, height: 0.95)),
            ),
          ),
          const SizedBox(height: 16),
          _Reveal(
            active: a,
            order: 2,
            child: Text(
              s.partial
                  ? 'Zatím. Rok ještě neskončil.'
                  : (s.isDecade ? 'Deset let. Pojďme na to.' : 'Pojďme se podívat, co ti hrálo.'),
              style: _text(20, FontWeight.w600, opacity: 0.9, height: 1.25),
            ),
          ),
          const Spacer(flex: 2),
        ],
      ),
    ),
    _Slide(
      style: MixArtStyle.mood,
      hue: hue(40),
      trackId: t(1) ?? t(0),
      build: (a) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Reveal(active: a, order: 0, child: Text('Čas s hudbou', style: _text(22, FontWeight.w700, opacity: 0.9))),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _CountUp(value: s.totalMinutes, active: a, style: _text(84, FontWeight.w900, height: 1)),
          ),
          _Reveal(active: a, order: 1, child: Text('minut', style: _text(34, FontWeight.w800))),
          const SizedBox(height: 28),
          _Reveal(
            active: a,
            order: 3,
            child: Text(
              'To je $days ${_plural(days, 'den', 'dny', 'dní')} hudby v kuse.\n'
              '${wrappedNumber(s.plays)} přehrání · ${wrappedNumber(s.daysListened)} ${_plural(s.daysListened, 'den', 'dny', 'dní')} s hudbou',
              style: _text(19, FontWeight.w600, opacity: 0.9, height: 1.35),
            ),
          ),
        ],
      ),
    ),
    if (s.topArtists.isNotEmpty)
      _Slide(
        style: MixArtStyle.genre,
        hue: hue(-30),
        trackId: a(0),
        build: (a) {
          final top = s.topArtists.first;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Reveal(
                active: a,
                order: 0,
                child: Text(s.isDecade ? 'Interpret dekády' : 'Interpret roku',
                    style: _text(22, FontWeight.w700, opacity: 0.9)),
              ),
              const SizedBox(height: 24),
              _Reveal(
                active: a,
                order: 1,
                child: _Art(url: top.imageUrl, artistId: top.id, size: 210, circle: true),
              ),
              const SizedBox(height: 24),
              _Reveal(
                active: a,
                order: 2,
                child: Text(top.name, textAlign: TextAlign.center, style: _text(40, FontWeight.w900)),
              ),
              const SizedBox(height: 10),
              _Reveal(
                active: a,
                order: 3,
                child: Text(
                  '${wrappedNumber(top.minutes)} minut · ${wrappedNumber(top.plays)} přehrání',
                  style: _text(18, FontWeight.w600, opacity: 0.9),
                ),
              ),
            ],
          );
        },
      ),
    if (s.topArtists.length > 1)
      _Slide(
        style: MixArtStyle.daily,
        hue: hue(-60),
        trackId: a(1),
        build: (a) => _RankList(
          active: a,
          title: 'Tvoji top interpreti',
          rows: [
            for (final artist in s.topArtists)
              _RankRow(
                title: artist.name,
                subtitle: '${wrappedNumber(artist.minutes)} min',
                art: _Art(url: artist.imageUrl, artistId: artist.id, size: 58, circle: true),
              ),
          ],
        ),
      ),
    if (s.topTracks.isNotEmpty)
      _Slide(
        style: MixArtStyle.mood,
        hue: hue(80),
        trackId: t(0),
        build: (a) {
          final top = s.topTracks.first;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Reveal(
                active: a,
                order: 0,
                child: Text(s.isDecade ? 'Skladba dekády' : 'Skladba roku',
                    style: _text(22, FontWeight.w700, opacity: 0.9)),
              ),
              const SizedBox(height: 24),
              _Reveal(
                active: a,
                order: 1,
                child: _Art(url: top.imageUrl, releaseId: top.releaseId, artistId: top.artistId, size: 230),
              ),
              const SizedBox(height: 24),
              _Reveal(
                active: a,
                order: 2,
                child: Text(top.title, textAlign: TextAlign.center, maxLines: 2, style: _text(34, FontWeight.w900)),
              ),
              if (top.artistName != null)
                _Reveal(
                  active: a,
                  order: 2,
                  child: Text(top.artistName!,
                      textAlign: TextAlign.center, style: _text(20, FontWeight.w600, opacity: 0.85)),
                ),
              const SizedBox(height: 14),
              _Reveal(
                active: a,
                order: 3,
                child: Text(
                  '${wrappedNumber(top.plays)}× přehráno · ${wrappedNumber(top.minutes)} minut',
                  style: _text(18, FontWeight.w600, opacity: 0.9),
                ),
              ),
            ],
          );
        },
      ),
    if (s.topTracks.length > 1)
      _Slide(
        style: MixArtStyle.daily,
        hue: hue(120),
        trackId: t(2),
        build: (a) => _RankList(
          active: a,
          title: 'Tvoje top skladby',
          rows: [
            for (final t in s.topTracks)
              _RankRow(
                title: t.title,
                subtitle: '${t.artistName ?? ''} · ${wrappedNumber(t.plays)}×',
                art: _Art(url: t.imageUrl, releaseId: t.releaseId, artistId: t.artistId, size: 58),
              ),
          ],
        ),
      ),
    if (s.isDecade && s.eras.isNotEmpty)
      _Slide(
        style: MixArtStyle.year,
        hue: hue(160),
        trackId: s.eras.isEmpty ? null : s.eras.first.track.id,
        build: (a) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Reveal(active: a, order: 0, child: Text('Tvoje éry', style: _text(34, FontWeight.w900))),
            const SizedBox(height: 16),
            for (final (i, era) in s.eras.indexed)
              _Reveal(
                active: a,
                order: 1 + i ~/ 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      SizedBox(width: 62, child: Text('${era.year}', style: _text(18, FontWeight.w900, opacity: 0.75))),
                      Expanded(
                        child: Text(
                          era.artist.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _text(20, FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    if (s.isDecade && s.evergreens.isNotEmpty)
      _Slide(
        style: MixArtStyle.genre,
        hue: hue(200),
        trackId: s.evergreens.isEmpty ? null : s.evergreens.first.id,
        build: (a) => _RankList(
          active: a,
          title: 'Nesmrtelné',
          subtitle: 'Skladby, které se ti vracely rok co rok',
          rows: [
            for (final t in s.evergreens)
              _RankRow(
                title: t.title,
                subtitle: '${t.artistName ?? ''} · v top 100 ${t.years} ${_plural(t.years, 'rok', 'roky', 'let')}',
                art: _Art(url: t.imageUrl, releaseId: t.releaseId, artistId: t.artistId, size: 58),
              ),
          ],
        ),
      ),
    if (s.topGenres.isNotEmpty)
      _Slide(
        style: MixArtStyle.genre,
        hue: hue(-100),
        trackId: t(3),
        build: (a) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Reveal(active: a, order: 0, child: Text('Tvoje žánry', style: _text(34, FontWeight.w900))),
            const SizedBox(height: 22),
            for (final (i, g) in s.topGenres.indexed)
              _Reveal(
                active: a,
                order: 1 + i,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(g.title, style: _text(21, FontWeight.w800))),
                          Text('${g.percent} %', style: _text(21, FontWeight.w900)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _GrowBar(
                        active: a,
                        fraction: g.percent / math.max(1, s.topGenres.first.percent),
                        color: HSLColor.fromColor(g.color).withLightness(0.62).withSaturation(0.75).toColor(),
                      ),
                      const SizedBox(height: 4),
                      Text('${wrappedNumber(g.minutes)} minut', style: _text(14, FontWeight.w600, opacity: 0.75)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    _Slide(
      style: MixArtStyle.daily,
      hue: hue(150),
      trackId: s.topNewArtist?.trackId ?? t(4),
      build: (a) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Reveal(active: a, order: 0, child: Text('Objevy', style: _text(22, FontWeight.w700, opacity: 0.9))),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _CountUp(
              value: s.isDecade ? s.artistsCount : s.newArtists,
              active: a,
              style: _text(84, FontWeight.w900, height: 1),
            ),
          ),
          _Reveal(
            active: a,
            order: 1,
            child: Text(
              s.isDecade ? 'různých interpretů za deset let' : 'nových interpretů',
              style: _text(26, FontWeight.w800),
            ),
          ),
          if (s.topNewArtist case final n? when !s.isDecade) ...[
            const SizedBox(height: 34),
            _Reveal(
              active: a,
              order: 3,
              child: Row(
                children: [
                  _Art(url: n.imageUrl, artistId: n.id, size: 76, circle: true),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Největší objev', style: _text(15, FontWeight.w700, opacity: 0.8)),
                        Text(n.name, maxLines: 2, style: _text(24, FontWeight.w900)),
                        Text('${wrappedNumber(n.minutes)} minut', style: _text(15, FontWeight.w600, opacity: 0.8)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
    _Slide(
      style: MixArtStyle.mood,  // graf/souhrn: klidná aurora, ne sloupce, co vypadají jako data
      hue: hue(-150),
      trackId: a(2),
      build: (a) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Reveal(
            active: a,
            order: 0,
            child: Text(s.isDecade ? 'Deset let v číslech' : 'Tvůj rok po měsících', style: _text(30, FontWeight.w900)),
          ),
          const SizedBox(height: 22),
          _Reveal(
            active: a,
            order: 1,
            child: SizedBox(
              height: 200,
              child: _BarChart(
                active: a,
                values: [for (final t in s.timeline) t.minutes],
                labels: [
                  for (final t in s.timeline)
                    s.isDecade ? "'${(t.key % 100).toString().padLeft(2, '0')}" : _monthShort[t.key - 1],
                ],
              ),
            ),
          ),
          const SizedBox(height: 30),
          _Reveal(
            active: a,
            order: 2,
            child: Text('Nejvíc posloucháš kolem', style: _text(18, FontWeight.w600, opacity: 0.85)),
          ),
          _Reveal(
            active: a,
            order: 3,
            child: Text('${s.peakHour}:00', style: _text(64, FontWeight.w900, height: 1)),
          ),
          const SizedBox(height: 10),
          _Reveal(
            active: a,
            order: 4,
            child: SizedBox(height: 60, child: _BarChart(active: a, values: s.hours, highlight: s.peakHour)),
          ),
        ],
      ),
    ),
    _Slide(
      style: MixArtStyle.mood,  // graf/souhrn: klidná aurora, ne sloupce, co vypadají jako data
      hue: hue(0),
      trackId: t(0),
      build: (a) => _Summary(stats: s, active: a),
    ),
  ];
  return slides;
}

class _RankRow {
  const _RankRow({required this.title, required this.subtitle, required this.art});
  final String title;
  final String subtitle;
  final Widget art;
}

class _RankList extends StatelessWidget {
  const _RankList({required this.active, required this.title, required this.rows, this.subtitle});
  final bool active;
  final String title;
  final String? subtitle;
  final List<_RankRow> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Reveal(active: active, order: 0, child: Text(title, style: _text(34, FontWeight.w900))),
        if (subtitle != null)
          _Reveal(active: active, order: 0, child: Text(subtitle!, style: _text(16, FontWeight.w600, opacity: 0.85))),
        const SizedBox(height: 22),
        for (final (i, row) in rows.indexed)
          _Reveal(
            active: active,
            order: 1 + i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  SizedBox(width: 34, child: Text('${i + 1}', style: _text(26, FontWeight.w900, opacity: 0.8))),
                  row.art,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: _text(19, FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(
                          row.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _text(14, FontWeight.w600, opacity: 0.8),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _GrowBar extends StatelessWidget {
  const _GrowBar({required this.active, required this.fraction, required this.color});
  final bool active;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(active),
      tween: Tween(begin: 0, end: active ? fraction.clamp(0.04, 1.0) : 0),
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Container(
        height: 12,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: v,
          child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6))),
        ),
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.active, required this.values, this.labels, this.highlight});
  final bool active;
  final List<int> values;
  final List<String>? labels;
  final int? highlight;

  @override
  Widget build(BuildContext context) {
    final peak = values.fold<int>(1, math.max);
    return TweenAnimationBuilder<double>(
      key: ValueKey(active),
      tween: Tween(begin: 0, end: active ? 1 : 0),
      duration: const Duration(milliseconds: 1300),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: values.length > 14 ? 1 : 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: FractionallySizedBox(
                        heightFactor: math.max(0.03, values[i] / peak * t),
                        child: Container(
                          decoration: BoxDecoration(
                            color: highlight == null || highlight == i
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(AppRadii.xxs),
                          ),
                        ),
                      ),
                    ),
                    if (labels != null) ...[
                      const SizedBox(height: 6),
                      Text(labels![i], style: _text(11, FontWeight.w700, opacity: 0.8)),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Závěrečná karta jako na Spotify -- všechno podstatné na jednom obrázku.
class _Summary extends StatelessWidget {
  const _Summary({required this.stats, required this.active});
  final WrappedStats stats;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    Widget column(String title, List<String> items) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _text(14, FontWeight.w800, opacity: 0.8)),
              const SizedBox(height: 8),
              for (final (i, item) in items.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    '${i + 1}  $item',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _text(15, FontWeight.w700),
                  ),
                ),
            ],
          ),
        );
    return _Reveal(
      active: active,
      order: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (s.topArtists.isNotEmpty)
            Center(child: _Art(url: s.topArtists.first.imageUrl, artistId: s.topArtists.first.id, size: 170, circle: true)),
          const SizedBox(height: 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              column('Top interpreti', [for (final a in s.topArtists) a.name]),
              const SizedBox(width: 14),
              column('Top skladby', [for (final t in s.topTracks) t.title]),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Minut', style: _text(14, FontWeight.w800, opacity: 0.8)),
                    Text(wrappedNumber(s.totalMinutes), style: _text(28, FontWeight.w900)),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Top žánr', style: _text(14, FontWeight.w800, opacity: 0.8)),
                    Text(
                      s.topGenres.isEmpty ? '–' : s.topGenres.first.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _text(28, FontWeight.w900),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
