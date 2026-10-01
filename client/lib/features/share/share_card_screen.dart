import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/share_image.dart';
import '../../data/lyrics_repository.dart';
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart' show ArtworkImage;

final _cardLyricsProvider = FutureProvider.autoDispose.family<LyricsModel?, String>(
  (ref, id) => ref.watch(lyricsRepositoryProvider).getLyrics(id),
);

/// „Sdílet jako obrázek" (jako Spotify): karta skladby a karta s právě
/// hrajícími řádky textu, 9:16 pro stories. Pozadí z barvy alba se zrnem.
/// Obrázek se vykreslí dopředu -- iPhone sdílí jen přímo z klepnutí.
class ShareCardScreen extends ConsumerStatefulWidget {
  const ShareCardScreen({
    super.key,
    required this.recordingId,
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.accent,
    required this.position,
  });

  final String recordingId;
  final String title;
  final String? artist;
  final String? artworkUrl;
  final Color accent;
  final Duration position;

  @override
  ConsumerState<ShareCardScreen> createState() => _ShareCardScreenState();
}

class _ShareCardScreenState extends ConsumerState<ShareCardScreen> {
  final _keys = [GlobalKey(), GlobalKey()];
  final _page = PageController(viewportFraction: 0.82);
  final Map<String, Uint8List> _rendered = {};
  int _index = 0;
  int? _lineStart; // první řádek na kartě s textem
  Timer? _renderTimer;
  bool _sharing = false;

  static const _linesOnCard = 4;

  @override
  void dispose() {
    _renderTimer?.cancel();
    _page.dispose();
    super.dispose();
  }

  List<String> _allLines(LyricsModel? lyrics) {
    if (lyrics == null) return const [];
    if (lyrics.hasSynced) return lyrics.syncedLines!.map((l) => l.text).toList();
    return (lyrics.plain ?? '').split('\n').map((l) => l.trim()).toList();
  }

  /// Výchozí: řádek, který zrovna hraje (synchronizovaný text).
  int _defaultStart(LyricsModel? lyrics) {
    if (lyrics == null || !lyrics.hasSynced) return 0;
    final lines = lyrics.syncedLines!;
    var i = lines.lastIndexWhere((l) => l.time <= widget.position);
    if (i < 0) i = 0;
    while (i < lines.length - 1 && lines[i].text.isEmpty) {
      i++;
    }
    return i;
  }

  List<String> _cardLines(List<String> all, int start) {
    final out = <String>[];
    for (var i = start; i < all.length && out.length < _linesOnCard; i++) {
      if (all[i].isNotEmpty) out.add(all[i]);
    }
    return out;
  }

  String get _key => '$_index:${_lineStart ?? -1}';

  void _scheduleRender() {
    _renderTimer?.cancel();
    final key = _key;
    if (_rendered.containsKey(key)) return;
    _renderTimer = Timer(const Duration(milliseconds: 500), () async {
      final png = await _capture(_index);
      if (png != null && mounted) _rendered[key] = png;
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
    final name = 'opentify-${widget.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}.png';
    final text = widget.artist == null ? widget.title : '${widget.title} – ${widget.artist}';
    final ready = _rendered[_key];
    if (ready != null) {
      unawaited(shareImage(ready, fileName: name, text: text)); // přímo z klepnutí
      return;
    }
    setState(() => _sharing = true);
    final png = await _capture(_index);
    if (mounted) setState(() => _sharing = false);
    if (png != null) await shareImage(png, fileName: name, text: text);
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = ref.watch(_cardLyricsProvider(widget.recordingId)).valueOrNull;
    final all = _allLines(lyrics);
    final hasLyrics = all.any((l) => l.isNotEmpty);
    final start = _lineStart ?? _defaultStart(lyrics);
    final lines = _cardLines(all, start);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRender());

    final cards = [
      _CardFrame(
        repaintKey: _keys[0],
        accent: widget.accent,
        child: _SongCard(title: widget.title, artist: widget.artist, artworkUrl: widget.artworkUrl),
      ),
      if (hasLyrics)
        _CardFrame(
          repaintKey: _keys[1],
          accent: widget.accent,
          child: _LyricsCard(
            title: widget.title,
            artist: widget.artist,
            artworkUrl: widget.artworkUrl,
            lines: lines,
          ),
        ),
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Sdílet jako obrázek'),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _page,
              onPageChanged: (i) => setState(() => _index = i),
              children: [
                for (final card in cards)
                  Center(child: Padding(padding: const EdgeInsets.all(10), child: card)),
              ],
            ),
          ),
          if (_index == 1 && hasLyrics)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Dřívější řádky',
                  color: Colors.white,
                  icon: const Icon(Symbols.keyboard_arrow_up_rounded),
                  onPressed: start <= 0 ? null : () => setState(() => _lineStart = math.max(0, start - 1)),
                ),
                const Text('Vyber řádky', style: TextStyle(color: Colors.white70)),
                IconButton(
                  tooltip: 'Další řádky',
                  color: Colors.white,
                  icon: const Icon(Symbols.keyboard_arrow_down_rounded),
                  onPressed: start >= all.length - 1 ? null : () => setState(() => _lineStart = start + 1),
                ),
              ],
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 16 + MediaQuery.paddingOf(context).bottom),
            child: SizedBox(
              width: double.infinity,
              child: GlassButton(
                label: _sharing ? 'Připravuji…' : 'Sdílet',
                icon: Symbols.ios_share_rounded,
                style: GlassButtonStyle.prominent,
                onPressed: _share,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 9:16 rám s pozadím z barvy alba a zrnem -- tohle se vykresluje do PNG.
class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.repaintKey, required this.accent, required this.child});

  final GlobalKey repaintKey;
  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(accent);
    final top = hsl.withLightness((hsl.lightness * 0.9).clamp(0.25, 0.55)).toColor();
    final bottom = hsl.withLightness(0.08).withSaturation((hsl.saturation * 0.8).clamp(0, 1)).toColor();
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: RepaintBoundary(
        key: repaintKey,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [top, Color.lerp(top, bottom, 0.55)!, bottom],
                  ),
                ),
              ),
              const CustomPaint(painter: _GrainPainter()),
              Padding(padding: const EdgeInsets.all(26), child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({required this.title, required this.artist, required this.artworkUrl});

  final String title;
  final String? artist;
  final String? artworkUrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ArtworkImage(url: artworkUrl, icon: Symbols.music_note_rounded),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.15),
        ),
        if (artist != null) ...[
          const SizedBox(height: 4),
          Text(artist!, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 17)),
        ],
        const Spacer(),
        const _Brand(),
      ],
    );
  }
}

class _LyricsCard extends StatelessWidget {
  const _LyricsCard({required this.title, required this.artist, required this.artworkUrl, required this.lines});

  final String title;
  final String? artist;
  final String? artworkUrl;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ArtworkImage(url: artworkUrl, icon: Symbols.music_note_rounded),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                  if (artist != null)
                    Text(artist!, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
            ),
          ],
        ),
        const Spacer(),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              line,
              style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800, height: 1.2),
            ),
          ),
        const Spacer(),
        const _Brand(),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => const Row(
        children: [
          Icon(Symbols.graphic_eq_rounded, color: Colors.white, size: 20),
          SizedBox(width: 6),
          Text('Opentify', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
        ],
      );
}

/// Statické filmové zrno (pevné semínko -- stejný obrázek při každém
/// vykreslení).
class _GrainPainter extends CustomPainter {
  const _GrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final light = <Offset>[];
    final dark = <Offset>[];
    final count = (size.width * size.height / 9).round();
    for (var i = 0; i < count; i++) {
      final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      (rnd.nextBool() ? light : dark).add(p);
    }
    canvas.drawPoints(
      ui.PointMode.points,
      light,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.07)
        ..strokeWidth = 1,
    );
    canvas.drawPoints(
      ui.PointMode.points,
      dark,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.10)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


/// Otevře kartu ke sdílení pro právě hrající skladbu (menu přehrávače,
/// screenshot na iPhonu).
void openShareCard(BuildContext context) {
  final playback = ProviderScope.containerOf(context, listen: false).read(audioPlayerControllerProvider);
  final np = playback.nowPlaying;
  if (np == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ShareCardScreen(
      recordingId: np.recordingId,
      title: np.title,
      artist: np.artistName,
      artworkUrl: np.artworkUrl,
      accent: playback.accentColor ?? Theme.of(context).colorScheme.primary,
      position: playback.position,
    ),
  ));
}
