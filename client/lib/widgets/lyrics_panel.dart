import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/lyrics_repository.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import '../theme/glass_tokens.dart';
import 'glass/expressive_shapes.dart';
import 'glass/glass.dart';

final _lyricsProvider = FutureProvider.autoDispose.family<LyricsModel?, String>((ref, recordingId) {
  return ref.watch(lyricsRepositoryProvider).getLyrics(recordingId);
});

/// Vytáhne text skladby z LRCLIB (přes backend proxy, viz `LyricsRepository`)
/// jako "Now Playing"-styl bottom sheet -- inspirováno Finampovou
/// `LyricsScreen` (github.com/jmshrv/finamp): synchronizovaný text se
/// zvýrazňuje a autoscrolluje podle pozice přehrávání, klik na řádek
/// seekne. Zjednodušeno oproti Finampu -- řádkové zvýraznění, ne
/// karaoke po písmenech (to by vyžadovalo slovní časování, které LRCLIB
/// běžně nenabízí).
Future<void> showLyricsPanel(BuildContext context, {required String recordingId, required Color accentColor}) {
  return showGlassSheet(
    context,
    builder: (context) => _LyricsPanel(recordingId: recordingId, accentColor: accentColor),
  );
}

class _LyricsPanel extends ConsumerWidget {
  const _LyricsPanel({required this.recordingId, required this.accentColor});

  final String recordingId;
  final Color accentColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, sheetController) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
        child: GlassContainer.frosted(
          // Stejné hustě namrzlé, skladbou tónované sklo jako přehrávač pod ním.
          borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTokens.sheetRadius)),
          tint: accentColor,
          fit: StackFit.expand,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 6),
              Expanded(child: LyricsView(recordingId: recordingId, scrollController: sheetController)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ruční posun časování textu pro skladbu (kladný = text dřív). Jen po dobu
/// běhu appky -- řeší zbylé případy, kdy verze textu sedí délkou, ale
/// zpěv je o kus posunutý.
final lyricsOffsetProvider = StateProvider.family<Duration, String>((ref, recordingId) => Duration.zero);

/// Text skladby bez obalu (sheet, sloupec v přehrávači na PC, režim textu
/// ve velkém přehrávači). Posun časování je v menu "⋯" přehrávače
/// (`LyricsTimingRow`), ne v textu.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({super.key, required this.recordingId, this.scrollController, this.immersive = false, this.color});

  final String recordingId;
  final ScrollController? scrollController;

  /// Režim jako v Apple Music: velké tučné řádky zarovnané vlevo, aktuální
  /// jasný, minulé ztlumené, budoucí ztlumené a čím dál rozmazanější; bez
  /// nadpisu.
  final bool immersive;

  /// Barva textu -- výchozí `onSurface` motivu (dřív natvrdo bílá, na
  /// světlém skle nečitelná).
  final Color? color;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  /// Řádek se rozsvítí o kousek dřív -- oko ho musí stihnout přečíst, než
  /// zazní, a pozice z přehrávače chodí s malým zpožděním.
  static const _lead = Duration(milliseconds: 350);

  // Menu "⋯" ukazuje posun časování jen, když je text na obrazovce.
  late final StateController<int> _visible = ref.read(lyricsVisibleProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _visible.state++);
  }

  @override
  void dispose() {
    final visible = _visible;
    WidgetsBinding.instance.addPostFrameCallback((_) => visible.state--);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recordingId = widget.recordingId;
    final immersive = widget.immersive;
    final scrollController = widget.scrollController;
    final lyricsAsync = ref.watch(_lyricsProvider(recordingId));
    final position = ref.watch(audioPlayerControllerProvider.select((s) => s.position));
    final offset = ref.watch(lyricsOffsetProvider(recordingId));
    final fg = widget.color ?? Theme.of(context).colorScheme.onSurface;
    final muted = TextStyle(color: fg.withValues(alpha: 0.7));

    return Column(
      children: [
        if (!immersive)
          SizedBox(
            height: 40,
            child: Center(child: Text('TEXT SKLADBY', style: muted.copyWith(fontSize: 12, letterSpacing: 2))),
          ),
        Expanded(
          child: lyricsAsync.when(
            data: (lyrics) {
              if (lyrics == null || !lyrics.hasAny) {
                return Center(child: Text('Text není k dispozici.', style: muted));
              }
              if (lyrics.instrumental) {
                return Center(child: Text('Instrumentální skladba.', style: muted));
              }
              if (lyrics.hasSynced) {
                return _SyncedLyricsList(
                  lines: lyrics.syncedLines!,
                  position: position + _lead + offset,
                  onSeek: (time) => ref.read(audioPlayerControllerProvider.notifier).seek(time - offset),
                  immersive: immersive,
                  color: fg,
                );
              }
              return SingleChildScrollView(
                controller: scrollController,
                padding: EdgeInsets.symmetric(horizontal: immersive ? 4 : 24, vertical: 16),
                child: Text(
                  lyrics.plain ?? '',
                  style: immersive
                      ? TextStyle(color: fg, fontSize: 24, fontWeight: FontWeight.w800, height: 1.35)
                      : TextStyle(color: fg, fontSize: 16, height: 1.6),
                  textAlign: immersive ? TextAlign.start : TextAlign.center,
                ),
              );
            },
            loading: () => Center(child: ExpressiveLoadingIndicator(color: fg)),
            error: (error, stack) => Center(child: Text('Text se nepodařilo načíst.', style: muted)),
          ),
        ),
      ],
    );
  }

}

/// Kolik zobrazení textu je právě na obrazovce (režim textu v přehrávači,
/// sheet, sloupec na PC) -- menu "⋯" podle toho ukáže posun časování.
final lyricsVisibleProvider = StateProvider<int>((ref) => 0);

/// Posun časování textu (menu "⋯" přehrávače, jen když je text vidět):
/// "Text později" / hodnota / "Text dřív".
class LyricsTimingRow extends ConsumerWidget {
  const LyricsTimingRow({super.key, required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final synced = ref.watch(_lyricsProvider(recordingId)).valueOrNull?.hasSynced ?? false;
    if (!synced) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final offset = ref.watch(lyricsOffsetProvider(recordingId));
    final seconds = (offset.inMilliseconds.abs() / 1000).toStringAsFixed(1).replaceAll('.', ',');
    final label = offset == Duration.zero ? 'Časování textu' : 'Posun ${offset.isNegative ? '−' : '+'}$seconds s';
    void shift(int direction) =>
        ref.read(lyricsOffsetProvider(recordingId).notifier).update((d) => d + Duration(milliseconds: 500 * direction));
    return Row(
      children: [
        Icon(Symbols.lyrics_rounded, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 16),
        Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
        IconButton(
          tooltip: 'Text později (−0,5 s)',
          icon: const Icon(Symbols.fast_rewind_rounded),
          onPressed: () => shift(-1),
        ),
        IconButton(
          tooltip: 'Text dřív (+0,5 s)',
          icon: const Icon(Symbols.fast_forward_rounded),
          onPressed: () => shift(1),
        ),
      ],
    );
  }
}

class _SyncedLyricsList extends StatefulWidget {
  const _SyncedLyricsList({
    required this.lines,
    required this.position,
    required this.onSeek,
    required this.immersive,
    required this.color,
  });

  final List<LyricLine> lines;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final bool immersive;
  final Color color;

  @override
  State<_SyncedLyricsList> createState() => _SyncedLyricsListState();
}

class _SyncedLyricsListState extends State<_SyncedLyricsList> {
  late List<GlobalKey> _keys = List.generate(widget.lines.length, (_) => GlobalKey());
  int _currentIndex = -1;
  bool _userScrolling = false;
  Timer? _resumeTimer;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _SyncedLyricsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines != widget.lines) {
      _keys = List.generate(widget.lines.length, (_) => GlobalKey());
      _currentIndex = -1;
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _indexForPosition(Duration position) {
    var result = -1;
    for (var i = 0; i < widget.lines.length; i++) {
      if (widget.lines[i].time <= position) {
        result = i;
      } else {
        break;
      }
    }
    return result;
  }

  void _maybeAutoScroll() {
    final index = _indexForPosition(widget.position);
    if (index == _currentIndex) return;
    final first = _currentIndex < 0;
    _currentIndex = index;
    if (_userScrolling || index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(index, animate: !first));
  }

  /// ListView staví jen řádky kolem výřezu -- aktuální řádek dál v textu
  /// (text otevřený uprostřed skladby) nemá context, `ensureVisible` pak
  /// nedělalo nic a text zůstal na začátku bez zvýraznění (živě nahlášeno).
  /// Proto nejdřív skok na odhad podle průměrné výšky řádku, pak doladit.
  void _scrollTo(int index, {required bool animate, int attempt = 0}) {
    if (!mounted || index != _currentIndex || _userScrolling) return;
    final ctx = _keys[index].currentContext;
    if (ctx != null) {
      if (animate) {
        Scrollable.ensureVisible(ctx,
            alignment: _alignment, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
      } else {
        Scrollable.ensureVisible(ctx, alignment: _alignment);
      }
      return;
    }
    if (attempt >= 4 || !_scroll.hasClients) return;
    final pos = _scroll.position;
    // Průměrná výška z postavených řádků, jinak ~40 px.
    var built = 0;
    var height = 0.0;
    for (final k in _keys) {
      final box = k.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        built++;
        height += box.size.height;
      }
    }
    final avg = built > 0 ? height / built : 40.0;
    final target =
        (_padTop + index * avg - pos.viewportDimension * _alignment).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    pos.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(index, animate: false, attempt: attempt + 1));
  }

  // Apple Music drží aktuální řádek v horní třetině, sheet uprostřed.
  double get _alignment => widget.immersive ? 0.18 : 0.4;
  double get _padTop => widget.immersive ? 24 : 140;

  @override
  Widget build(BuildContext context) {
    _maybeAutoScroll();
    return NotificationListener<ScrollNotification>(
      // Uživatelovo ruční přetažení pozastaví autoscroll na pár vteřin --
      // jinak by mu ho aktuální pozice hned "vyrvala" zpátky, stejná
      // nepříjemnost, kterou řeší Finampovo `isAutoScrollEnabled`.
      onNotification: (notification) {
        if (notification is ScrollStartNotification && notification.dragDetails != null) {
          _userScrolling = true;
        } else if (notification is ScrollEndNotification) {
          _resumeTimer?.cancel();
          _resumeTimer = Timer(const Duration(seconds: 3), () {
            if (mounted) setState(() => _userScrolling = false);
          });
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        padding: widget.immersive
            ? EdgeInsets.only(top: _padTop, bottom: 320, left: 4, right: 4)
            : const EdgeInsets.symmetric(vertical: 140, horizontal: 28),
        itemCount: widget.lines.length,
        itemBuilder: (context, index) {
          final line = widget.lines[index];
          final isCurrent = index == _currentIndex;
          final fg = widget.color;
          if (widget.immersive) return _immersiveLine(line, index, isCurrent, fg);
          return Padding(
            key: _keys[index],
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: GestureDetector(
              onTap: () => widget.onSeek(line.time),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  color: isCurrent ? fg : fg.withValues(alpha: 0.45),
                  fontSize: isCurrent ? 22 : 18,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
                ),
                child: Text(line.text.isEmpty ? '♪' : line.text),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Řádek v režimu Apple Music: všechny řádky stejně velké a tučné (text
  /// neposkakuje), aktuální jasný, ostatní ztlumené; budoucí se s každým
  /// řádkem dál víc rozmazávají, minulé jen lehce. Při ručním scrollu vše
  /// ostré, ať jde číst dopředu.
  Widget _immersiveLine(LyricLine line, int index, bool isCurrent, Color fg) {
    final distance = _currentIndex < 0 ? index + 1 : index - _currentIndex;
    final sigma = _userScrolling || distance == 0 ? 0.0 : (distance > 0 ? math.min(3.2, distance * 0.9) : 0.8);
    return Padding(
      key: _keys[index],
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSeek(line.time),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: sigma),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          builder: (context, blur, child) => blur < 0.05
              ? child!
              : ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: child),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 350),
            style: TextStyle(
              color: isCurrent ? fg : fg.withValues(alpha: distance < 0 ? 0.32 : 0.4),
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.2,
              letterSpacing: -0.3,
            ),
            child: Text(line.text.isEmpty ? '♪' : line.text),
          ),
        ),
      ),
    );
  }
}
