import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/lyrics_repository.dart';
import '../state/audio_player_controller.dart';
import '../state/glass_settings.dart';
import '../state/providers.dart';
import '../theme/glass_tokens.dart';
import 'glass/expressive_shapes.dart';
import 'glass/glass.dart';
import '../theme/design_tokens.dart';

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
          liquid: true,
          fit: StackFit.expand,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2)),
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
    final offset = ref.watch(lyricsOffsetProvider(recordingId));
    final fg = widget.color ?? Theme.of(context).colorScheme.onSurface;
    final muted = TextStyle(color: fg.withValues(alpha: 0.7));

    return Column(
      children: [
        if (!immersive)
          SizedBox(
            height: 40,
            child: Center(child: Text('TEXT SKLADBY', style: muted.copyWith(fontSize: AppFontSize.caption, letterSpacing: 2))),
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
              final follow = !ref.watch(lyricsFollowOffProvider).contains(recordingId);
              if (lyrics.hasSynced && follow) {
                final lines = lyrics.syncedLines!;
                // Jen začátek AKTUÁLNÍHO řádku -- text se překreslí, až se řádek
                // změní, ne 5x za vteřinu s každou pozicí (audit výkonu).
                final lineStart = ref.watch(audioPlayerControllerProvider.select((s) {
                  final at = s.position + _lead + offset;
                  Duration? start;
                  for (final l in lines) {
                    if (l.time <= at) {
                      start = l.time;
                    } else {
                      break;
                    }
                  }
                  return start ?? const Duration(microseconds: -1);
                }));
                return _SyncedLyricsList(
                  lines: lines,
                  position: lineStart,
                  onSeek: (time) => ref.read(audioPlayerControllerProvider.notifier).seek(time - offset),
                  immersive: immersive,
                  color: fg,
                );
              }
              // Sledování vypnuté (nebo text bez časů): jen ke čtení.
              final plain = lyrics.plain ?? lyrics.syncedLines?.map((l) => l.text).join(String.fromCharCode(10)) ?? '';
              return SingleChildScrollView(
                controller: scrollController,
                padding: EdgeInsets.symmetric(horizontal: immersive ? 4 : 24, vertical: 16),
                child: Text(
                  plain,
                  style: immersive
                      ? TextStyle(color: fg, fontSize: AppFontSize.display, fontWeight: FontWeight.w800, height: 1.35)
                      : TextStyle(color: fg, fontSize: AppFontSize.lead, height: 1.6),
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

/// Režim textu v přehrávači (telefon) jako přepínač: zůstává zapnutý přes
/// další skladby, zavření přehrávače i nové spuštění appky -- dřív se
/// s každým otevřením přehrávače vrátil na obal.
class LyricsModeController extends StateNotifier<bool> {
  LyricsModeController() : super(false) {
    _load();
  }

  static const _prefKey = 'player.lyrics_mode';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    if (value == state) return;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
  }
}

final lyricsModeProvider = StateNotifierProvider<LyricsModeController, bool>((ref) => LyricsModeController());

/// Posun časování textu (menu "⋯" přehrávače, jen když je text vidět):
/// "Text později" / hodnota / "Text dřív".
/// Skladby, u kterých uživatel vypnul sledování textu (špatně načasovaný
/// text) -- text je pak jen ke čtení, bez posouvání a zvýrazňování.
/// Pamatuje se natrvalo pro každou skladbu zvlášť.
class LyricsFollowOffController extends StateNotifier<Set<String>> {
  LyricsFollowOffController() : super(const {}) {
    _load();
  }

  static const _prefKey = 'lyrics.follow_off';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_prefKey);
      if (saved != null && mounted) state = saved.toSet();
    } catch (_) {}
  }

  Future<void> setFollow(String recordingId, bool follow) async {
    state = follow ? ({...state}..remove(recordingId)) : {...state, recordingId};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, state.toList());
    } catch (_) {}
  }
}

final lyricsFollowOffProvider =
    StateNotifierProvider<LyricsFollowOffController, Set<String>>((ref) => LyricsFollowOffController());

/// Ikona "sledovat text" přímo v přehrávači (mobil: místo srdíčka v řádku
/// nad textem, PC: roh sloupce s textem). Jen u textu s časy.
class LyricsFollowButton extends ConsumerWidget {
  const LyricsFollowButton({super.key, required this.recordingId, this.color, this.activeColor});

  final String recordingId;
  final Color? color;

  /// Barva zapnutého stavu (barva skladby), jinak `color`.
  final Color? activeColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final synced = ref.watch(_lyricsProvider(recordingId)).valueOrNull?.hasSynced ?? false;
    if (!synced) return const SizedBox.shrink();
    final follow = !ref.watch(lyricsFollowOffProvider).contains(recordingId);
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return IconButton(
      tooltip: follow ? 'Vypnout sledování textu' : 'Zapnout sledování textu',
      // Stejně jako přepínače v ovládání přehrávače (Text, Náhodně...).
      style: IconButton.styleFrom(
        foregroundColor: follow ? (activeColor ?? fg) : fg.withValues(alpha: 0.55),
        fixedSize: const Size.square(44),
      ),
      icon: Icon(
        follow ? Symbols.subtitles_rounded : Symbols.subtitles_off_rounded,
        size: 22,
        fill: follow ? 1 : 0,
        semanticLabel: follow ? 'Sledování textu zapnuté' : 'Sledování textu vypnuté',
      ),
      onPressed: () => ref.read(lyricsFollowOffProvider.notifier).setFollow(recordingId, !follow),
    );
  }
}

/// Menu "⋯" přehrávače (jen když je text vidět): přepínač "Sledovat text"
/// pro tuhle skladbu -- místo dřívějšího posouvání časování.
class LyricsTimingRow extends ConsumerWidget {
  const LyricsTimingRow({super.key, required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final synced = ref.watch(_lyricsProvider(recordingId)).valueOrNull?.hasSynced ?? false;
    if (!synced) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final follow = !ref.watch(lyricsFollowOffProvider).contains(recordingId);
    return Row(
      children: [
        Icon(Symbols.lyrics_rounded, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sledovat text', style: theme.textTheme.bodyLarge),
              Text(
                'U téhle skladby text sám posouvat a zvýrazňovat',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        GlassSwitch(
          value: follow,
          semanticLabel: 'Sledovat text',
          onChanged: (v) => ref.read(lyricsFollowOffProvider.notifier).setFollow(recordingId, v),
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
      if (animate && !MediaQuery.disableAnimationsOf(ctx)) {
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
            if (!mounted) return;
            setState(() => _userScrolling = false);
            // Zpátky na aktuální řádek hned, ne až s dalším řádkem textu.
            if (_currentIndex >= 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_currentIndex, animate: true));
            }
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
                  // Stejné velikosti jako dřív (22/18), jen ze škály.
                  fontSize: isCurrent ? AppFontSize.heading : AppFontSize.titleLarge,
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
    // Bez skla (slabší zařízení) a s omezeným pohybem jen ztlumení, žádné
    // rozmazání. Jinak tři stupně (minulé / další 1-2 / zbytek) místo
    // sigmy pro každý řádek zvlášť -- vzdálené řádky se při posunu textu
    // nemění, takže se jejich rozmazání nepřepočítává (výkon).
    final noBlur = GlassSettings.solidOf(context) || MediaQuery.disableAnimationsOf(context);
    final double sigma;
    if (noBlur || _userScrolling || distance == 0) {
      sigma = 0;
    } else if (distance < 0) {
      sigma = 0.8;
    } else if (distance <= 2) {
      sigma = 1.4;
    } else {
      sigma = 3.2;
    }
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
          // Stejný strom s rozmazáním i bez (`enabled`) -- přepínání typu
          // widgetu řádek znovu stavělo a text probliknul.
          builder: (context, blur, child) => ImageFiltered(
            enabled: blur >= 0.05,
            imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: child,
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 350),
            style: TextStyle(
              color: isCurrent ? fg : fg.withValues(alpha: distance < 0 ? 0.32 : 0.4),
              fontSize: AppFontSize.xl,
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
