import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/home_repository.dart';
import 'media_card.dart' show ArtworkImage;

/// Styl generativního obalu vlastního mixu (backend `PlaylistCardOut.art_style`).
enum MixArtStyle { daily, genre, mood, year }

/// Co obal potřebuje: styl, stálý seed (stejný mix = pořád stejný obrázek),
/// barvu, velký text (číslo mixu / žánr / rok) a fotky interpretů.
class MixArtSpec {
  const MixArtSpec({
    required this.style,
    required this.seed,
    required this.headline,
    this.color,
    this.photos = const [],
    this.eyebrow,
  });

  final MixArtStyle style;
  final String seed;
  final String headline;
  final Color? color;
  final List<String> photos;

  /// Popisek nahoře místo výchozího ("DENNÍ MIX", "TOP SKLADBY"...).
  final String? eyebrow;
}

Color? _hex(String? hex) {
  if (hex == null) return null;
  final value = int.tryParse('FF${hex.replaceFirst('#', '')}', radix: 16);
  return value == null ? null : Color(value);
}

/// Obal karty, nebo `null` pro obyčejné playlisty (mozaika obalů).
MixArtSpec? mixArtOf(HomePlaylistCard card) => mixArtForSource(
      source: card.source,
      title: card.title,
      photos: card.coverUrls,
      color: _hex(card.accentColor),
      categoryGroup: card.artStyle == 'mood' ? 'mood' : null,
    );

/// Obal vlastního mixu jen ze zdroje playlistu (`personal:daily-mix:2`,
/// `personal:year:2019`, `personal:category-mix:jazz`...) -- stejný na kartě
/// na Domů i v hlavičce playlistu. `null` = obyčejný playlist.
/// `categoryGroup` (mood/genre) a `color` jen u mixů kategorií.
MixArtSpec? mixArtForSource({
  required String? source,
  required String title,
  List<String> photos = const [],
  Color? color,
  String? categoryGroup,
}) {
  final s = source ?? '';
  final last = s.split(':').last;
  if (s.startsWith('personal:daily-mix:')) {
    return MixArtSpec(style: MixArtStyle.daily, seed: s, headline: last, photos: photos);
  }
  if (s.startsWith('personal:year:')) {
    return MixArtSpec(style: MixArtStyle.year, seed: s, headline: last, photos: photos);
  }
  if (s.startsWith('personal:decade:')) {
    return MixArtSpec(style: MixArtStyle.year, seed: s, headline: '16–26', photos: photos, eyebrow: 'DEKÁDA');
  }
  if (s.startsWith('personal:category-mix:')) {
    final i = title.indexOf('· ');
    return MixArtSpec(
      style: categoryGroup == 'mood' ? MixArtStyle.mood : MixArtStyle.genre,
      seed: s,
      headline: i < 0 ? title : title.substring(i + 2),
      color: color,
      photos: photos,
    );
  }
  return null;
}

/// Generativní obal vlastního mixu -- každý druh mixu vlastní výtvarný
/// styl, v rámci druhu se liší barvou a seedem:
///   * Denní mix: vrstvené vlny,
///   * žánr: soustředné drážky (deska, jako ikona appky),
///   * nálada: měkké barevné aurory,
///   * rok: sloupce ekvalizéru a velký letopočet.
/// Obsahová vrstva podle glass_tokens.dart -- tón + zrno, žádné sklo.
class MixArtwork extends StatelessWidget {
  const MixArtwork({super.key, required this.spec, this.compact = false, this.labels = true});

  final MixArtSpec spec;

  /// Malá dlaždice (Rychlý výběr, 56 px) -- bez popisků a fotek.
  final bool compact;

  /// alse = jen kresba bez nápisů (pozadí hlavičky, kde je název zvlášť).
  final bool labels;

  static const _dailyHues = [268.0, 12.0, 196.0, 142.0, 330.0, 38.0];

  double get _hue {
    if (spec.color case final c?) return HSLColor.fromColor(c).hue;
    switch (spec.style) {
      case MixArtStyle.daily:
        final n = int.tryParse(spec.headline) ?? 1;
        return _dailyHues[(n - 1) % _dailyHues.length];
      case MixArtStyle.year:
        final y = int.tryParse(spec.headline) ?? 0;
        return (y * 47 + 20) % 360;
      default:
        return (_seedOf(spec.seed) % 360).toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hue = _hue;
    final seed = _seedOf(spec.seed);
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final CustomPainter painter = switch (spec.style) {
          MixArtStyle.daily => _WavesPainter(hue, seed),
          MixArtStyle.genre => _GroovesPainter(hue, seed),
          MixArtStyle.mood => _AuroraPainter(hue, seed),
          MixArtStyle.year => _BarsPainter(hue, seed),
        };
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: painter)),
            const RepaintBoundary(child: CustomPaint(painter: GrainPainter())),
            if (labels) ..._overlay(context, side),
          ],
        );
      },
    );
  }

  List<Widget> _overlay(BuildContext context, double side) {
    const shadow = [Shadow(blurRadius: 10, color: Colors.black38)];
    final eyebrow = spec.eyebrow ??
        switch (spec.style) {
          MixArtStyle.daily => 'DENNÍ MIX',
          MixArtStyle.year => 'TOP SKLADBY',
          _ => 'TVŮJ MIX',
        };
    final label = compact
        ? null
        : Positioned(
            left: side * 0.08,
            top: side * 0.07,
            child: Text(
              eyebrow,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: math.max(9, side * 0.065),
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                shadows: shadow,
              ),
            ),
          );

    switch (spec.style) {
      case MixArtStyle.daily:
        final photos = spec.photos.take(compact ? 0 : 3).toList();
        final avatar = side * 0.27;
        return [
          if (label != null) label,
          Positioned(
            left: side * 0.07,
            bottom: side * (compact ? 0.04 : 0.02),
            child: Text(
              spec.headline,
              style: TextStyle(
                color: Colors.white,
                fontSize: side * (compact ? 0.62 : 0.42),
                fontWeight: FontWeight.w900,
                height: 1,
                shadows: shadow,
              ),
            ),
          ),
          for (var i = 0; i < photos.length; i++)
            Positioned(
              right: side * 0.06 + i * avatar * 0.6,
              bottom: side * 0.08,
              width: avatar,
              height: avatar,
              child: DecoratedBox(
                decoration: const ShapeDecoration(
                  shape: CircleBorder(side: BorderSide(color: Colors.white, width: 2)),
                  shadows: [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: ClipOval(child: ArtworkImage(url: photos[i], icon: Symbols.person_rounded, iconSize: 16)),
              ),
            ),
        ];
      case MixArtStyle.year:
        return [
          if (label != null) label,
          Positioned(
            left: side * 0.07,
            top: compact ? side * 0.08 : side * 0.15,
            child: Text(
              compact ? '’${spec.headline.substring(math.max(0, spec.headline.length - 2))}' : spec.headline,
              style: TextStyle(
                color: Colors.white,
                fontSize: side * (compact ? 0.42 : 0.27),
                fontWeight: FontWeight.w900,
                height: 1,
                letterSpacing: -side * 0.008,
                shadows: shadow,
              ),
            ),
          ),
        ];
      case MixArtStyle.genre:
      case MixArtStyle.mood:
        if (compact) return const [];
        final mood = spec.style == MixArtStyle.mood;
        return [
          if (label != null) label,
          Positioned(
            left: side * 0.08,
            right: side * 0.08,
            // Žánr nahoře pod popiskem (drážky jsou vpravo dole), nálada dole.
            top: mood ? null : side * 0.17,
            bottom: mood ? side * 0.08 : null,
            child: Text(
              spec.headline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: side * 0.15,
                fontWeight: mood ? FontWeight.w700 : FontWeight.w900,
                fontStyle: mood ? FontStyle.italic : FontStyle.normal,
                height: 1.05,
                shadows: shadow,
              ),
            ),
          ),
        ];
    }
  }
}

/// Samotná generativní kresba (bez popisků) přes celou plochu -- pozadí
/// obrazovek Wrappedu ve stejném výtvarném jazyce jako obaly mixů.
class MixBackground extends StatelessWidget {
  const MixBackground({super.key, required this.style, required this.hue, required this.seed});

  final MixArtStyle style;
  final double hue;
  final String seed;

  @override
  Widget build(BuildContext context) {
    final s = _seedOf(seed);
    final CustomPainter painter = switch (style) {
      MixArtStyle.daily => _WavesPainter(hue, s),
      MixArtStyle.genre => _GroovesPainter(hue, s),
      MixArtStyle.mood => _AuroraPainter(hue, s),
      MixArtStyle.year => _BarsPainter(hue, s),
    };
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: CustomPaint(painter: painter)),
        const RepaintBoundary(child: CustomPaint(painter: GrainPainter())),
      ],
    );
  }
}

int _seedOf(String s) => s.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff);

Color _hsl(double h, double s, double l, [double a = 1]) =>
    HSLColor.fromAHSL(a, (h % 360 + 360) % 360, s.clamp(0.0, 1.0), l.clamp(0.0, 1.0)).toColor();

void _fillBase(Canvas canvas, Size size, double hue, {double light = 0.44, double dark = 0.16}) {
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_hsl(hue, 0.6, light), _hsl(hue + 30, 0.66, dark)],
      ).createShader(rect),
  );
}

/// Denní mix: 5 vrstvených vln přes celou šířku, odspodu tmavší.
class _WavesPainter extends CustomPainter {
  _WavesPainter(this.hue, this.seed);
  final double hue;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final w = size.width, h = size.height;
    _fillBase(canvas, size, hue, light: 0.5, dark: 0.22);
    const bands = 5;
    for (var i = 0; i < bands; i++) {
      final baseY = h * (0.3 + i * 0.15);
      final amp = h * (0.04 + rnd.nextDouble() * 0.06);
      final freq = 1.0 + rnd.nextDouble() * 1.6;
      final phase = rnd.nextDouble() * math.pi * 2;
      final path = Path()..moveTo(0, h);
      for (var x = 0.0; x <= w; x += w / 40) {
        path.lineTo(x, baseY + math.sin(x / w * math.pi * 2 * freq + phase) * amp);
      }
      path
        ..lineTo(w, h)
        ..close();
      final shift = (i.isEven ? 1 : -1) * (12.0 + i * 9);
      canvas.drawPath(path, Paint()..color = _hsl(hue + shift, 0.7, 0.5 - i * 0.07, 0.55));
    }
  }

  @override
  bool shouldRepaint(_WavesPainter old) => old.hue != hue || old.seed != seed;
}

/// Žánr: soustředné drážky desky z rohu (vpravo dole), různá tloušťka a jas.
class _GroovesPainter extends CustomPainter {
  _GroovesPainter(this.hue, this.seed);
  final double hue;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final w = size.width, h = size.height;
    _fillBase(canvas, size, hue, light: 0.36, dark: 0.12);
    final center = Offset(w * (0.78 + rnd.nextDouble() * 0.3), h * (0.8 + rnd.nextDouble() * 0.3));
    final maxR = w * 0.95;
    // Plná "deska" s jemným přechodem.
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..shader = RadialGradient(
          colors: [_hsl(hue, 0.5, 0.08), _hsl(hue, 0.6, 0.22), _hsl(hue - 20, 0.7, 0.4)],
          stops: const [0.2, 0.7, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: maxR)),
    );
    var r = maxR * 0.28;
    while (r < maxR) {
      final width = w * (0.004 + rnd.nextDouble() * 0.014);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = _hsl(
              hue + rnd.nextDouble() * 40 - 20, 0.75, 0.55 + rnd.nextDouble() * 0.2, 0.2 + rnd.nextDouble() * 0.45),
      );
      r += w * (0.022 + rnd.nextDouble() * 0.03);
    }
    // Lesk přes drážky.
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..shader = SweepGradient(
          center: Alignment(center.dx / w * 2 - 1, center.dy / h * 2 - 1),
          colors: [Colors.transparent, Colors.white.withValues(alpha: 0.12), Colors.transparent],
          stops: const [0.55, 0.64, 0.73],
        ).createShader(Offset.zero & size),
    );
    // Střed desky.
    canvas.drawCircle(center, maxR * 0.2, Paint()..color = _hsl(hue + 20, 0.45, 0.42));
    canvas.drawCircle(center, maxR * 0.035, Paint()..color = Colors.black.withValues(alpha: 0.85));
  }

  @override
  bool shouldRepaint(_GroovesPainter old) => old.hue != hue || old.seed != seed;
}

/// Nálada: 4 měkké rozostřené skvrny (aurora) na tmavém tónovaném pozadí.
class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.hue, this.seed);
  final double hue;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final w = size.width, h = size.height;
    _fillBase(canvas, size, hue, light: 0.18, dark: 0.08);
    final offsets = [0.0, 45.0, -50.0, 180.0];
    for (var i = 0; i < 4; i++) {
      final c = Offset(w * (0.1 + rnd.nextDouble() * 0.8), h * (0.05 + rnd.nextDouble() * 0.75));
      final radius = w * (0.45 + rnd.nextDouble() * 0.35);
      final color = _hsl(hue + offsets[i], i == 3 ? 0.4 : 0.8, i == 3 ? 0.75 : 0.58, i == 3 ? 0.35 : 0.75);
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..blendMode = BlendMode.screen
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(
            Rect.fromCircle(center: c, radius: radius),
          ),
      );
    }
    // Ztmavení dole, ať je název čitelný.
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.35)],
          stops: const [0.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.hue != hue || old.seed != seed;
}

/// Rok: sloupce ekvalizéru ve spodní polovině, střídavě dva tóny.
class _BarsPainter extends CustomPainter {
  _BarsPainter(this.hue, this.seed);
  final double hue;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final w = size.width, h = size.height;
    _fillBase(canvas, size, hue, light: 0.42, dark: 0.14);
    const bars = 9;
    final gap = w * 0.025;
    final barW = (w - gap * (bars + 1)) / bars;
    for (var i = 0; i < bars; i++) {
      final height = h * (0.18 + rnd.nextDouble() * 0.42);
      final x = gap + i * (barW + gap);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, h - height, barW, height + barW),
        topLeft: Radius.circular(barW / 2),
        topRight: Radius.circular(barW / 2),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _hsl(hue + (i.isEven ? 35 : -25), 0.8, 0.62),
              _hsl(hue + (i.isEven ? 35 : -25), 0.75, 0.3, 0.6),
            ],
          ).createShader(rect.outerRect),
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.hue != hue || old.seed != seed;
}

/// Statické jemné zrno (stejná estetika jako pozadí appky, jen levné).
class GrainPainter extends CustomPainter {
  const GrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(3);
    final count = (size.width * size.height / 14).clamp(200, 4000).toInt();
    final light = <Offset>[];
    final dark = <Offset>[];
    for (var i = 0; i < count; i++) {
      final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      (rnd.nextBool() ? light : dark).add(p);
    }
    final paint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawPoints(ui.PointMode.points, light, paint..color = Colors.white.withValues(alpha: 0.10));
    canvas.drawPoints(ui.PointMode.points, dark, paint..color = Colors.black.withValues(alpha: 0.12));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
