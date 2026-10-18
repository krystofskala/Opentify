import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../features/browse/browse_grid.dart' show genreIcon;
import 'media_card.dart' show ArtworkImage;
import 'mix_artwork.dart' show GrainPainter, MixArtSpec, MixArtStyle;

/// Obaly mixů verze 2 (14. 10., schváleno; nákres a pravidla:
/// https://claude.ai/artifact/2nJRd7t1CeEsVYiPvZBApr).
///
/// Pravidla:
/// * každý tvar je fakt (Objevy: kruhy = skladby, zvlnění = tempo; denní
///   mix: vlny = podíly stylů; Top roku: sloupce = poslechy po měsících),
/// * ploché barvy: pozadí střední sytosti + jedna tmavá + jedna světlá,
/// * značka vlevo nahoře (lišta 7 × 1,2 %), pod ní popisek a drobný fakt,
/// * Archivo: název 12,5 % strany, účaří v 93 %; čísla 40 %; popisek 3,8 %,
/// * fotka jen v kruhu / horní části a vždy ve dvou barvách obalu,
/// * malá dlaždice a široká dlaždice mají vlastní zjednodušenou verzi.
enum CoverKind { discover, daily, genre, mood, year, decade, onRepeat, throwback, homeMix }

CoverKind? coverKindOf(MixArtSpec spec) {
  final s = spec.seed;
  if (s.startsWith('personal:discover-weekly')) return CoverKind.discover;
  if (s.startsWith('personal:daily-mix:')) return CoverKind.daily;
  if (s.startsWith('personal:year:')) return CoverKind.year;
  if (s.startsWith('personal:decade:')) return CoverKind.decade;
  if (s.startsWith('personal:on-repeat')) return CoverKind.onRepeat;
  if (s.startsWith('personal:throwback')) return CoverKind.throwback;
  if (s.startsWith('home:mix:')) return CoverKind.homeMix;
  if (s.startsWith('personal:category-mix:') || s.startsWith('personal:tag:')) {
    return spec.style == MixArtStyle.mood ? CoverKind.mood : CoverKind.genre;
  }
  return null;
}

class _Pal {
  const _Pal(this.bg, this.mid, this.deep, this.ink, this.light, [Color? accent]) : accent = accent ?? light;
  final Color bg, mid, deep, ink, light, accent;
}

Color _hsl(double h, double s, double l) =>
    HSLColor.fromAHSL(1, (h % 360 + 360) % 360, s.clamp(0.0, 1.0), l.clamp(0.0, 1.0)).toColor();

const _dailyPals = [
  _Pal(Color(0xFFE2553F), Color(0xFFF08A6D), Color(0xFFB13A2A), Color(0xFF3A1611), Color(0xFFFFE2D8)),
  _Pal(Color(0xFFD9A23A), Color(0xFFECC66F), Color(0xFFA8761C), Color(0xFF33240A), Color(0xFFFFF1D2)),
  _Pal(Color(0xFF3F74C9), Color(0xFF7EA2E0), Color(0xFF2A4F99), Color(0xFF0F1A33), Color(0xFFE3ECFB)),
  _Pal(Color(0xFF8A5CC4), Color(0xFFB393E3), Color(0xFF63399B), Color(0xFF1D0F33), Color(0xFFEFE6FB)),
  _Pal(Color(0xFF2F9A7A), Color(0xFF6CC7A8), Color(0xFF1F6F57), Color(0xFF0B241C), Color(0xFFE0F5EE)),
  _Pal(Color(0xFFC7457A), Color(0xFFE88BB0), Color(0xFF963059), Color(0xFF2E0C1C), Color(0xFFFBE3EE)),
];

// (pozadí, sloupce, nejsilnější měsíc, text)
const _yearPals = [
  _Pal(Color(0xFF22473A), Color(0xFF8FD9B8), Color(0xFF8FD9B8), Color(0xFF22473A), Color(0xFFEEF7F1), Color(0xFFE9FF7A)),
  _Pal(Color(0xFF3B2A5C), Color(0xFFB7A3EC), Color(0xFFB7A3EC), Color(0xFF3B2A5C), Color(0xFFF2EEFC), Color(0xFFFFB36B)),
  _Pal(Color(0xFF5A2C22), Color(0xFFF0A58F), Color(0xFFF0A58F), Color(0xFF5A2C22), Color(0xFFFCECE7), Color(0xFFFFE07A)),
];

// Nálady s vlastní paletou z nákresu; ostatní z barvy kategorie.
const _moodPals = {
  'sad': _Pal(Color(0xFF34506E), Color(0xFF7FA6C8), Color(0xFFB9CFE2), Color(0xFFE8F0F7), Color(0xFFE8F0F7), Color(0xFF7FA6C8)),
  'romance': _Pal(Color(0xFF7A2B44), Color(0xFFF08CA0), Color(0xFFFFB38A), Color(0xFFFDE9EC), Color(0xFFFDE9EC), Color(0xFFF08CA0)),
  'morning': _Pal(Color(0xFFC8622D), Color(0xFFFFCF6E), Color(0xFFFFE9B8), Color(0xFF2D1407), Color(0xFF2D1407), Color(0xFFFFCF6E)),
};

double _hueOf(MixArtSpec spec) => spec.color != null ? HSLColor.fromColor(spec.color!).hue : spec.hue;

_Pal _palette(CoverKind kind, MixArtSpec spec) {
  switch (kind) {
    case CoverKind.discover:
      final week = _int(spec.facts, 'week') ?? 0;
      final h = 168.0 + (week * 23) % 40;
      return _Pal(_hsl(h, 0.48, 0.30), _hsl(h - 8, 0.70, 0.74), _hsl(h + 6, 0.55, 0.14), _hsl(h + 6, 0.55, 0.14),
          _hsl(h - 10, 0.45, 0.90), _hsl(h - 8, 0.70, 0.74));
    case CoverKind.daily:
      final n = int.tryParse(spec.headline) ?? 1;
      return _dailyPals[(n - 1) % _dailyPals.length];
    case CoverKind.year:
      final y = int.tryParse(spec.headline) ?? 0;
      return _yearPals[y % _yearPals.length];
    case CoverKind.genre:
      final h = _hueOf(spec);
      return _Pal(_hsl(h, 0.55, 0.50), _hsl(h, 0.75, 0.76), _hsl(h, 0.5, 0.07), _hsl(h, 0.5, 0.07), _hsl(h, 0.6, 0.92),
          _hsl(h, 0.75, 0.76));
    case CoverKind.decade:
      return const _Pal(Color(0xFF1F2A44), Color(0xFF8FB3FF), Color(0xFF8FB3FF), Color(0xFF1F2A44), Color(0xFFEEF2FF),
          Color(0xFFFFD166));
    case CoverKind.onRepeat:
      return const _Pal(Color(0xFFB8456E), Color(0xFFF08FB0), Color(0xFF7E2447), Color(0xFF2A0A17), Color(0xFFFDE6EE),
          Color(0xFFFFD6E4));
    case CoverKind.throwback:
      return const _Pal(Color(0xFF3E6F73), Color(0xFF9CC9C4), Color(0xFF234547), Color(0xFF0D1F20), Color(0xFFF1EBDD),
          Color(0xFFE9C46A));
    case CoverKind.homeMix:
      final h = _hueOf(spec);
      return _Pal(_hsl(h, 0.5, 0.42), _hsl(h, 0.7, 0.7), _hsl(h, 0.5, 0.25), _hsl(h, 0.5, 0.08), _hsl(h, 0.4, 0.94),
          _hsl(h, 0.7, 0.7));
    case CoverKind.mood:
      final pal = _moodPals[_moodKey(spec)];
      if (pal != null) return pal;
      final h = _hueOf(spec);
      return _Pal(_hsl(h, 0.45, 0.32), _hsl(h, 0.70, 0.65), _hsl(h, 0.75, 0.82), _hsl(h, 0.4, 0.94), _hsl(h, 0.4, 0.94),
          _hsl(h, 0.70, 0.65));
  }
}

String _moodKey(MixArtSpec spec) => spec.seed.split(':').last;

int? _int(Map<String, dynamic>? m, String k) => (m?[k] as num?)?.toInt();

/// Archivo s proměnnou šířkou a tloušťkou.
TextStyle _archivo(double size, double weight, double width, {double tracking = 0, Color? color, double height = 1}) =>
    TextStyle(
      fontFamily: 'Archivo',
      fontSize: size,
      fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
      fontVariations: [FontVariation('wght', weight), FontVariation('wdth', width)],
      letterSpacing: size * tracking,
      height: height,
      color: color,
      decoration: TextDecoration.none,
    );

/// Fotka ve dvou barvách obalu: tmavá -> světlá podle jasu (s mírným
/// zvýšením kontrastu).
ColorFilter _duotone(Color dark, Color light) {
  List<double> row(double d, double l) {
    final k = (l - d) * 1.3;
    return [k * 0.3, k * 0.59, k * 0.11, 0, (d - (l - d) * 0.13) * 255];
  }

  return ColorFilter.matrix([
    ...row(dark.r, light.r),
    ...row(dark.g, light.g),
    ...row(dark.b, light.b),
    0, 0, 0, 1, 0,
  ]);
}

Widget _photo(String? url, Color dark, Color light) => ColorFiltered(
      colorFilter: _duotone(dark, light),
      child: ArtworkImage(url: url, icon: Symbols.person_rounded, iconSize: 18),
    );

/// Obal verze 2, nebo `null` pro druhy, které ho ještě nemají.
Widget? mixCoverV2(MixArtSpec spec, {bool compact = false, bool labels = true}) {
  final kind = coverKindOf(spec);
  if (kind == null) return null;
  return _MixCover(spec: spec, kind: kind, tile: compact, labels: labels && !compact);
}

class _MixCover extends StatelessWidget {
  const _MixCover({required this.spec, required this.kind, required this.tile, required this.labels});

  final MixArtSpec spec;
  final CoverKind kind;
  final bool tile;
  final bool labels;

  @override
  Widget build(BuildContext context) {
    final pal = _palette(kind, spec);
    final facts = spec.facts ?? const <String, dynamic>{};
    final photos = ((facts['photos'] as List<dynamic>?)?.cast<String>() ?? const <String>[]).isNotEmpty
        ? (facts['photos'] as List<dynamic>).cast<String>()
        : spec.photos;
    return LayoutBuilder(builder: (context, c) {
      final s = c.biggest.shortestSide;
      final children = <Widget>[ColoredBox(color: pal.bg)];
      switch (kind) {
        case CoverKind.discover:
          final cx = s * 0.64, cy = s * 0.16, r = s * 0.19;
          children.add(CustomPaint(painter: _DiscoverPainter(pal, facts, tile)));
          if (photos.isNotEmpty) {
            children.add(Positioned(
              left: cx - r,
              top: cy - r,
              width: r * 2,
              height: r * 2,
              child: ClipOval(child: _photo(photos.first, pal.ink, pal.light)),
            ));
          }
        case CoverKind.daily:
          if (photos.isNotEmpty) {
            children.add(Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: s * 0.62,
              child: _photo(photos.first, pal.ink, pal.light),
            ));
          }
          children.add(CustomPaint(painter: _DailyPainter(pal, facts, int.tryParse(spec.headline) ?? 1)));
          // Číslo celé nad spodní hranou (14. 10.: useknuté vypadalo zmáčknuté).
          children.add(Positioned(
            left: s * 0.055,
            bottom: s * 0.045,
            child: Text(spec.headline, style: _archivo(s * 0.34, 900, 125, tracking: -0.05, color: pal.light, height: 0.74)),
          ));
        case CoverKind.genre:
          children.add(CustomPaint(painter: _GenrePainter(pal, tile)));
          final lr = s * (tile ? 0.24 : 0.15);
          final lx = tile ? s * 0.6 : s * 0.78, ly = tile ? s * 0.42 : s * 0.34;
          // Štítek desky: fotka interpreta, jinak ikonka žánru jako v Hledat.
          children.add(Positioned(
            left: lx - lr,
            top: ly - lr,
            width: lr * 2,
            height: lr * 2,
            child: ClipOval(
              child: photos.isNotEmpty
                  ? _photo(photos.first, pal.ink, pal.mid)
                  : ColoredBox(
                      color: pal.mid,
                      child: Icon(genreIcon(spec.seed.split(':').last), size: lr * 1.1, color: pal.ink),
                    ),
            ),
          ));
        case CoverKind.mood:
          children.add(CustomPaint(painter: _MoodPainter(pal, _moodKey(spec), spec.seed)));
        case CoverKind.year:
          children.add(CustomPaint(painter: _YearPainter(pal, facts, tile)));
        case CoverKind.decade:
          children.add(CustomPaint(painter: _YearPainter(pal, facts, tile, decade: true)));
        case CoverKind.onRepeat:
          children.add(CustomPaint(painter: _RepeatPainter(pal, tile)));
        case CoverKind.homeMix:
          children.add(CustomPaint(painter: _MoodPainter(pal, '', spec.seed)));
        case CoverKind.throwback:
          // Polaroid s fotkou interpreta ve dvou barvách, za ním druhý natočený.
          final w = s * (tile ? 0.62 : 0.38);
          for (final (dx, dy, angle, front) in [(0.52, 0.17, 0.14, false), (0.46, 0.2, -0.08, true)]) {
            children.add(Positioned(
              left: s * dx,
              top: s * dy,
              width: w,
              height: w * 1.18,
              child: Transform.rotate(
                angle: angle,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: front ? pal.light : pal.mid),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(w * 0.07, w * 0.07, w * 0.07, w * 0.25),
                    child: front && photos.isNotEmpty
                        ? _photo(photos.first, pal.ink, pal.accent)
                        : ColoredBox(color: front ? pal.deep : pal.bg),
                  ),
                ),
              ),
            ));
          }
      }
      children.add(const IgnorePointer(child: CustomPaint(painter: GrainPainter())));
      if (labels) children.addAll(_texts(s, pal, facts));
      return ClipRect(child: Stack(fit: StackFit.expand, clipBehavior: Clip.hardEdge, children: children));
    });
  }

  List<Widget> _texts(double s, _Pal pal, Map<String, dynamic> facts) {
    final m = s * 0.07;
    final tracks = _int(facts, 'tracks');
    final artists = _int(facts, 'artists');
    String caption;
    String? fact;
    String? title;
    Color ink = pal.light;
    Color? plate;
    switch (kind) {
      case CoverKind.discover:
        final week = _int(facts, 'week');
        caption = week != null ? 'TÝDEN $week' : 'PRO TEBE';
        fact = tracks != null ? '$tracks skladeb${artists != null ? ' · $artists interpretů' : ''}' : null;
        title = 'Objevy\ntýdne';
      case CoverKind.daily:
        final style = facts['style'] as String?;
        caption = style == null ? 'DENNÍ MIX' : 'DENNÍ MIX · ${style.toUpperCase()}';
        fact = facts['artistsLine'] as String?;
        plate = pal.ink;
      case CoverKind.genre:
        caption = 'TVŮJ MIX';
        fact = tracks != null ? '$tracks skladeb${artists != null ? ' · $artists interpretů' : ''}' : null;
        title = spec.headline;
        ink = pal.ink;
      case CoverKind.mood:
        caption = 'NÁLADA';
        fact = tracks != null ? '$tracks skladeb' : null;
        title = spec.headline;
        ink = pal.ink;
      case CoverKind.year:
        caption = 'TOP SKLADBY';
        final months = (facts['months'] as List<dynamic>?)?.cast<num>();
        final total = months?.fold<num>(0, (a, b) => a + b).toInt();
        fact = total != null && total > 0 ? '${_thousands(total)} poslechů' : null;
      case CoverKind.decade:
        caption = 'DEKÁDA';
        final years = (facts['years'] as List<dynamic>?)?.cast<num>();
        final total = years?.fold<num>(0, (a, b) => a + b).toInt();
        fact = total != null && total > 0 ? '${_thousands(total)} poslechů' : null;
      case CoverKind.onRepeat:
        caption = 'POSLEDNÍ MĚSÍC';
        fact = tracks != null ? '$tracks skladeb' : null;
        title = 'Na\nopakování';
      case CoverKind.throwback:
        caption = 'ZNOVU OBJEVENO';
        fact = tracks != null ? '$tracks skladeb' : null;
        title = 'Návrat do\nminulosti';
      case CoverKind.homeMix:
        caption = 'MIX';
        fact = tracks != null ? '$tracks skladeb' : null;
        title = spec.headline;
        ink = pal.light;
    }
    final mark = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: s * 0.07, height: s * 0.012, color: kind == CoverKind.daily ? pal.light : pal.accent),
        SizedBox(height: s * 0.022),
        Text(caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _archivo(s * 0.038, 600, 87, tracking: 0.14, color: ink)),
        if (fact != null) ...[
          SizedBox(height: s * 0.012),
          Text(fact,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _archivo(s * 0.03, 500, 87, tracking: 0.06, color: ink.withValues(alpha: 0.75))),
        ],
      ],
    );
    return [
      Positioned(
        left: plate != null ? m - s * 0.025 : m,
        top: plate != null ? m - s * 0.025 : m,
        right: m,
        child: Align(
          alignment: Alignment.topLeft,
          child: plate == null
              ? mark
              : DecoratedBox(
                  decoration: BoxDecoration(color: plate),
                  child: Padding(padding: EdgeInsets.all(s * 0.025), child: mark),
                ),
        ),
      ),
      if (title != null)
        Positioned(
          left: m,
          right: s * 0.07,
          bottom: s * 0.06,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomLeft,
              child: Text(title, style: _archivo(s * 0.125, 800, 112, tracking: -0.03, color: ink, height: 0.88)),
            ),
          ),
        ),
      if (kind == CoverKind.decade)
        Positioned(
          left: s * 0.055,
          bottom: -s * 0.02,
          child: Text(
            spec.headline,
            style: _archivo(s * 0.21, 900, 125, tracking: -0.04, color: pal.light),
          ),
        ),
      if (kind == CoverKind.year)
        Positioned(
          left: s * 0.055,
          bottom: -s * 0.035,
          child: Text(
            '’${spec.headline.substring(math.max(0, spec.headline.length - 2))}',
            style: _archivo(s * 0.4, 900, 125, tracking: -0.05, color: pal.light),
          ),
        ),
    ];
  }
}

String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

/// Široká nízká dlaždice (Rychlý výběr): barva obalu, název vlevo, motiv
/// malé dlaždice vpravo ořízlý okrajem. Bez popisku a značky.
Widget? mixCoverWideV2(MixArtSpec spec, String title) {
  final kind = coverKindOf(spec);
  if (kind == null) return null;
  final pal = _palette(kind, spec);
  final ink = kind == CoverKind.genre || kind == CoverKind.mood ? pal.ink : pal.light;
  return LayoutBuilder(builder: (context, c) {
    final h = c.maxHeight, side = h * 1.5;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: pal.bg),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: h * 1.25,
          child: ClipRect(
            child: Stack(clipBehavior: Clip.hardEdge, children: [
              Positioned(
                left: h * 1.25 - side * 0.9,
                top: -side * 0.18,
                width: side,
                height: side,
                child: _MixCover(spec: spec, kind: kind, tile: true, labels: false),
              ),
            ]),
          ),
        ),
        Positioned(
          left: h * 0.22,
          right: h * 1.25 + h * 0.14,
          top: 0,
          bottom: 0,
          child: LayoutBuilder(builder: (context, t) {
            // Nejdelší slovo se musí vejít na řádek ("Moje nejpos / louchanější",
            // 18. 10.): Flutter jinak láme uprostřed slova. Písmo se zmenší,
            // nejvýš na 55 %.
            var style = _archivo(h * 0.26, 800, 112, tracking: -0.02, color: ink, height: 1.05);
            final longest = title.split(RegExp(r'\s+')).fold<String>('', (a, b) => b.length > a.length ? b : a);
            final painter = TextPainter(
              text: TextSpan(text: longest, style: style),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            if (painter.width > t.maxWidth && painter.width > 0) {
              style = style.copyWith(fontSize: style.fontSize! * math.max(0.55, t.maxWidth / painter.width * 0.98));
            }
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
            );
          }),
        ),
      ],
    );
  });
}

// --------------------------------------------------------------------------
// Motivy
// --------------------------------------------------------------------------

/// Objevy: kruhy z tváře ořízlé horním okrajem; počet = skladby / 2,
/// zvlnění podle tempa. Dlaždice: jen 3 silné kruhy.
class _DiscoverPainter extends CustomPainter {
  _DiscoverPainter(this.pal, this.facts, this.tile);
  final _Pal pal;
  final Map<String, dynamic> facts;
  final bool tile;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final tracks = _int(facts, 'tracks') ?? 28;
    final bpm = _int(facts, 'bpm') ?? 100;
    final week = _int(facts, 'week') ?? 0;
    final cx = s * 0.64, cy = s * 0.16, r = s * 0.19;
    final rings = tile ? 3 : (tracks / 2).round().clamp(8, 20);
    final amp = (0.02 + (bpm - 70) / 900).clamp(0.01, 0.12);
    final step = s * (tile ? 0.13 : 0.042);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, s * (tile ? 0.03 : 0.006));
    for (var i = 1; i <= rings; i++) {
      final path = Path();
      for (var a = 0.0; a <= math.pi * 2 + 0.01; a += 0.025) {
        final rr = (r + i * step) * (1 + amp * (i / rings) * math.sin(a * 4 + i * 0.5 + week));
        final p = Offset(cx + math.cos(a) * rr, cy + math.sin(a) * rr);
        a == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      final alpha = tile ? 1 - i * 0.22 : math.max(0.18, 1 - i / (rings + 4));
      canvas.drawPath(path, paint..color = pal.mid.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(_DiscoverPainter old) => old.facts != facts || old.tile != tile;
}

/// Denní mix: tři ploché vlny, výška vrstvy = podíl stylu v mixu.
class _DailyPainter extends CustomPainter {
  _DailyPainter(this.pal, this.facts, this.n);
  final _Pal pal;
  final Map<String, dynamic> facts;
  final int n;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final rnd = math.Random(n * 104729);
    var shares = ((facts['shares'] as List<dynamic>?) ?? const []).map((e) => (e as num).toDouble()).toList();
    if (shares.length < 3) shares = const [0.4, 0.33, 0.27];
    var y = s * 0.5;
    // Vlny přes celou šířku: v hlavičce detailu je plátno širší než vysoké a
    // vlny končily na `s` -- vpravo prosvítal obdélník fotky (18. 10.).
    final w = size.width, bottom = size.height;
    final colors = [pal.mid, pal.deep, pal.ink];
    for (var i = 0; i < 3; i++) {
      final f = 0.55 + rnd.nextDouble() * 0.45, amp = s * (0.022 + rnd.nextDouble() * 0.018), ph = rnd.nextDouble() * math.pi * 2;
      final path = Path()..moveTo(0, bottom);
      for (var x = 0.0; x <= w + 1; x += s / 80) {
        path.lineTo(x, y + math.sin(x / s * math.pi * 2 * f + ph) * amp);
      }
      path
        ..lineTo(w, bottom)
        ..close();
      canvas.drawPath(path, Paint()..color = colors[i]);
      y += s * 0.5 * shares[i];
    }
  }

  @override
  bool shouldRepaint(_DailyPainter old) => old.facts != facts || old.n != n;
}

/// Žánr: deska 110 % ořízlá rohem, jemné drážky, bez lesků (štítek = fotka).
class _GenrePainter extends CustomPainter {
  _GenrePainter(this.pal, this.tile);
  final _Pal pal;
  final bool tile;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(s * 0.82, s * 0.3), r = s * 0.55;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF17161A));
    if (!tile) {
      final groove = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.5, s * 0.0022)
        ..color = Colors.white.withValues(alpha: 0.055);
      for (var rr = r * 0.33; rr < r * 0.98; rr += s * 0.008) {
        canvas.drawCircle(c, rr, groove);
      }
    }
  }

  @override
  bool shouldRepaint(_GenrePainter old) => old.tile != tile || old.pal.bg != pal.bg;
}

/// Nálada: každá vlastní motiv (jeden tvar ořízlý okrajem).
class _MoodPainter extends CustomPainter {
  _MoodPainter(this.pal, this.key, this.seed);
  final _Pal pal;
  final String key;
  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final a = Paint()..color = pal.mid;
    final b = Paint()..color = pal.deep;
    switch (key) {
      case 'sad':
        // Padající kapky, největší ořízlá horním okrajem; nízký horizont.
        void drop(double x, double y, double w, Paint p) {
          final path = Path()
            ..moveTo(x, y - w * 1.5)
            ..cubicTo(x + w * 0.9, y - w * 0.2, x + w, y + w * 0.4, x, y + w)
            ..cubicTo(x - w, y + w * 0.4, x - w * 0.9, y - w * 0.2, x, y - w * 1.5);
          canvas.drawPath(path, p);
        }
        drop(s * 0.68, s * 0.12, s * 0.26, a);
        drop(s * 0.36, s * 0.42, s * 0.1, b);
        drop(s * 0.88, s * 0.56, s * 0.06, a);
        canvas.drawRect(Rect.fromLTWH(0, s * 0.74, s, s * 0.26), Paint()..color = Colors.black.withValues(alpha: 0.18));
      case 'romance':
        // Dva kruhy, které se prolínají; třetí malý ořízlý pravým okrajem.
        canvas.saveLayer(Offset.zero & size, Paint());
        canvas.drawCircle(Offset(s * 0.46, s * 0.4), s * 0.25, a);
        canvas.drawCircle(Offset(s * 0.7, s * 0.38), s * 0.25, Paint()
          ..color = pal.deep
          ..blendMode = BlendMode.screen);
        canvas.restore();
        canvas.drawCircle(Offset(s * 1.02, s * 0.74), s * 0.1, a);
      case 'morning':
        // Vycházející slunce nad horizontem, rozdělené pruhy.
        final c = Offset(s * 0.6, s * 0.62), r = s * 0.44;
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, s, c.dy));
        canvas.drawCircle(c, r, a);
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(Rect.fromLTWH(0, c.dy - s * (0.04 + i * 0.075), s, s * (0.012 + i * 0.004)), Paint()..color = pal.bg);
        }
        canvas.drawCircle(c, r * 0.3, b);
        canvas.restore();
      case 'sleep':
        // Srpek měsíce a pár hvězd.
        canvas.saveLayer(Offset.zero & size, Paint());
        canvas.drawCircle(Offset(s * 0.66, s * 0.34), s * 0.24, a);
        canvas.drawCircle(Offset(s * 0.76, s * 0.27), s * 0.21, Paint()..blendMode = BlendMode.clear);
        canvas.restore();
        for (final p in const [(0.22, 0.24, 0.012), (0.34, 0.44, 0.008), (0.9, 0.62, 0.01), (0.5, 0.14, 0.007)]) {
          canvas.drawCircle(Offset(s * p.$1, s * p.$2), s * p.$3, b);
        }
      case 'focus':
        // Terč: jeden bod a tenké soustředné kruhy, ořízlé pravým okrajem.
        final c = Offset(s * 0.74, s * 0.36);
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.012
          ..color = pal.mid;
        for (var i = 1; i <= 5; i++) {
          canvas.drawCircle(c, s * 0.07 * i, ring);
        }
        canvas.drawCircle(c, s * 0.04, b);
      case 'workout':
        // Šikmé tučné pruhy -- energie.
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, s, s * 0.72));
        for (var i = -2; i < 6; i++) {
          final x = s * (0.3 + i * 0.16);
          final path = Path()
            ..moveTo(x, 0)
            ..lineTo(x + s * 0.08, 0)
            ..lineTo(x + s * 0.08 - s * 0.4, s)
            ..lineTo(x - s * 0.4, s)
            ..close();
          canvas.drawPath(path, i.isEven ? a : b);
        }
        canvas.restore();
      case 'party':
        // Konfety: kruhy různé velikosti, jeden velký ořízlý.
        final rnd = math.Random(seed.hashCode);
        canvas.drawCircle(Offset(s * 0.86, s * 0.12), s * 0.2, a);
        for (var i = 0; i < 12; i++) {
          canvas.drawCircle(Offset(s * (0.15 + rnd.nextDouble() * 0.8), s * (0.12 + rnd.nextDouble() * 0.5)),
              s * (0.015 + rnd.nextDouble() * 0.035), i.isEven ? b : a);
        }
      case 'feelgood':
        // Slunce s krátkými paprsky.
        final c = Offset(s * 0.7, s * 0.32);
        canvas.drawCircle(c, s * 0.16, a);
        final ray = Paint()
          ..color = pal.deep
          ..strokeWidth = s * 0.03
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 10; i++) {
          final ang = i / 10 * math.pi * 2;
          canvas.drawLine(c + Offset(math.cos(ang), math.sin(ang)) * s * 0.22, c + Offset(math.cos(ang), math.sin(ang)) * s * 0.3, ray);
        }
      case 'roadtrip':
        // Silnice do perspektivy s přerušovanou čárou.
        final road = Path()
          ..moveTo(s * 0.62, s * 0.1)
          ..lineTo(s * 0.7, s * 0.1)
          ..lineTo(s * 1.1, s * 0.72)
          ..lineTo(s * 0.4, s * 0.72)
          ..close();
        canvas.drawPath(road, a);
        for (var i = 0; i < 5; i++) {
          final t = i / 5, t2 = t + 0.1;
          final x1 = s * (0.66 + 0.09 * t), x2 = s * (0.66 + 0.09 * t2);
          canvas.drawLine(Offset(x1, s * (0.1 + 0.62 * t)), Offset(x2, s * (0.1 + 0.62 * t2)), Paint()
            ..color = pal.deep
            ..strokeWidth = s * (0.006 + 0.02 * t));
        }
      default:
        // Ostatní (chill a další): dvě ploché vlny a kruh.
        canvas.drawCircle(Offset(s * 0.7, s * 0.3), s * 0.18, b);
        for (var i = 0; i < 2; i++) {
          final y = s * (0.46 + i * 0.12);
          final path = Path()..moveTo(0, s);
          for (var x = 0.0; x <= s + 1; x += s / 60) {
            path.lineTo(x, y + math.sin(x / s * math.pi * 2 * (0.8 + i * 0.3) + i) * s * 0.03);
          }
          path
            ..lineTo(s, s * 0.72)
            ..lineTo(0, s * 0.72)
            ..close();
          canvas.drawPath(path, i == 0 ? a : Paint()
            ..color = Colors.black.withValues(alpha: 0.15));
        }
    }
  }

  @override
  bool shouldRepaint(_MoodPainter old) => old.key != key || old.pal.bg != pal.bg;
}

/// Top roku: 12 sloupců = poslechy po měsících, nejsilnější měsíc
/// zvýrazněný a popsaný.
class _YearPainter extends CustomPainter {
  _YearPainter(this.pal, this.facts, this.tile, {this.decade = false});
  final _Pal pal;
  final Map<String, dynamic> facts;
  final bool tile;

  /// Dekáda: sloupce = roky (facts['years'], první rok facts['from']).
  final bool decade;

  static const _monthNames = [
    'LEDEN', 'ÚNOR', 'BŘEZEN', 'DUBEN', 'KVĚTEN', 'ČERVEN', 'ČERVENEC', 'SRPEN', 'ZÁŘÍ', 'ŘÍJEN', 'LISTOPAD', 'PROSINEC',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final key = decade ? 'years' : 'months';
    final count = decade ? 11 : 12;
    var months = ((facts[key] as List<dynamic>?) ?? const []).map((e) => (e as num).toDouble()).toList();
    if (months.isEmpty || months.every((v) => v == 0)) {
      final rnd = math.Random(7);
      months = List.generate(count, (_) => 0.3 + rnd.nextDouble());
    }
    final n = months.length;
    final m = s * 0.07, gap = s * 0.014, w = (s - 2 * m - gap * (n - 1)) / n;
    final base = tile ? s * 0.9 : s * 0.62, maxH = tile ? s * 0.75 : s * 0.3;
    final max = months.reduce(math.max);
    final peak = months.indexOf(max);
    for (var i = 0; i < n; i++) {
      final h = months[i] / max * maxH;
      canvas.drawRect(Rect.fromLTWH(m + i * (w + gap), base - h, w, h), Paint()..color = i == peak ? pal.accent : pal.mid);
    }
    if (tile || facts[key] == null) return;
    final label = decade ? '${(_int(facts, 'from') ?? 0) + peak}' : _monthNames[peak];
    final tp = TextPainter(
      text: TextSpan(text: label, style: _archivo(s * 0.03, 600, 87, tracking: 0.12, color: pal.accent)),
      textDirection: TextDirection.ltr,
    )..layout();
    final px = m + peak * (w + gap);
    final x = px + w > s * 0.6 ? px + w - tp.width : px;
    tp.paint(canvas, Offset(x, base - maxH - s * 0.02 - tp.height));
  }

  @override
  bool shouldRepaint(_YearPainter old) => old.facts != facts || old.tile != tile || old.decade != decade;
}

/// Na opakování: silná spirála (smyčka, která se opakuje) se šipkou na konci.
class _RepeatPainter extends CustomPainter {
  _RepeatPainter(this.pal, this.tile);
  final _Pal pal;
  final bool tile;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(s * (tile ? 0.5 : 0.66), s * (tile ? 0.5 : 0.4));
    final stroke = s * (tile ? 0.07 : 0.045);
    final path = Path();
    const turns = 2.3;
    Offset? last;
    for (var a = 0.0; a <= turns * math.pi * 2; a += 0.05) {
      final r = s * 0.035 + a * s * (tile ? 0.028 : 0.02);
      final p = c + Offset(math.cos(a), math.sin(a)) * r;
      last == null ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      last = p;
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = pal.mid);
    if (last != null) canvas.drawCircle(last, stroke * 0.9, Paint()..color = pal.accent);
  }

  @override
  bool shouldRepaint(_RepeatPainter old) => old.tile != tile || old.pal.bg != pal.bg;
}
