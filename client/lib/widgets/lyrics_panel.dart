import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/lyrics_repository.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import '../theme/glass_tokens.dart';
import 'glass_container.dart';
import 'glass/expressive_shapes.dart';

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
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
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

/// Text skladby bez obalu (sheet na mobilu, sloupec v přehrávači na PC):
/// nadpis s posunem časování + synchronizovaný/prostý text.
class LyricsView extends ConsumerWidget {
  const LyricsView({super.key, required this.recordingId, this.scrollController});

  final String recordingId;
  final ScrollController? scrollController;

  /// Řádek se rozsvítí o kousek dřív -- oko ho musí stihnout přečíst, než
  /// zazní, a pozice z přehrávače chodí s malým zpožděním.
  static const _lead = Duration(milliseconds: 350);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(_lyricsProvider(recordingId));
    final position = ref.watch(audioPlayerControllerProvider.select((s) => s.position));
    final offset = ref.watch(lyricsOffsetProvider(recordingId));
    final synced = lyricsAsync.valueOrNull?.hasSynced ?? false;

    return Column(
      children: [
        SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (synced) _offsetButton(ref, -1),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('TEXT SKLADBY', style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2)),
              ),
              if (synced) _offsetButton(ref, 1),
            ],
          ),
        ),
        if (synced && offset != Duration.zero)
          Text(
            'Posun ${offset.isNegative ? '−' : '+'}${(offset.inMilliseconds.abs() / 1000).toStringAsFixed(1)} s',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        Expanded(
          child: lyricsAsync.when(
            data: (lyrics) {
              if (lyrics == null || !lyrics.hasAny) {
                return const Center(child: Text('Text není k dispozici.', style: TextStyle(color: Colors.white70)));
              }
              if (lyrics.instrumental) {
                return const Center(child: Text('Instrumentální skladba.', style: TextStyle(color: Colors.white70)));
              }
              if (lyrics.hasSynced) {
                return _SyncedLyricsList(
                  lines: lyrics.syncedLines!,
                  position: position + _lead + offset,
                  onSeek: (time) => ref.read(audioPlayerControllerProvider.notifier).seek(time - offset),
                );
              }
              return SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Text(
                  lyrics.plain ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.6),
                  textAlign: TextAlign.center,
                ),
              );
            },
            loading: () => const Center(child: ExpressiveLoadingIndicator(color: Colors.white)),
            error: (error, stack) =>
                const Center(child: Text('Text se nepodařilo načíst.', style: TextStyle(color: Colors.white70))),
          ),
        ),
      ],
    );
  }

  Widget _offsetButton(WidgetRef ref, int direction) => IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        tooltip: direction > 0 ? 'Text dřív (+0,5 s)' : 'Text později (−0,5 s)',
        icon: Icon(direction > 0 ? Symbols.fast_forward_rounded : Symbols.fast_rewind_rounded, color: Colors.white70),
        onPressed: () => ref.read(lyricsOffsetProvider(recordingId).notifier).update(
              (d) => d + Duration(milliseconds: 500 * direction),
            ),
      );
}

class _SyncedLyricsList extends StatefulWidget {
  const _SyncedLyricsList({required this.lines, required this.position, required this.onSeek});

  final List<LyricLine> lines;
  final Duration position;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SyncedLyricsList> createState() => _SyncedLyricsListState();
}

class _SyncedLyricsListState extends State<_SyncedLyricsList> {
  late List<GlobalKey> _keys = List.generate(widget.lines.length, (_) => GlobalKey());
  int _currentIndex = -1;
  bool _userScrolling = false;
  Timer? _resumeTimer;

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
    _currentIndex = index;
    if (_userScrolling || index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.4, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

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
        padding: const EdgeInsets.symmetric(vertical: 140, horizontal: 28),
        itemCount: widget.lines.length,
        itemBuilder: (context, index) {
          final line = widget.lines[index];
          final isCurrent = index == _currentIndex;
          return Padding(
            key: _keys[index],
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: GestureDetector(
              onTap: () => widget.onSeek(line.time),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  color: isCurrent ? Colors.white : Colors.white.withValues(alpha: 0.45),
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
}
