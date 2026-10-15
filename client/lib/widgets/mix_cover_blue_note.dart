import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'media_card.dart' show ArtworkImage;
import 'mix_artwork.dart' show GrainPainter, MixArtSpec;
import 'mix_cover.dart' show CoverKind, coverKindOf;

/// Speciální série obalů ve stylu Blue Note / Reida Milese (15. 10., návrh
/// 8c-BN, vzor `claude/design/vzory/blue-note-denni-mix.html`). Vedle obalů v2,
/// ne místo nich; k čemu se použije, se rozhodne později (Kryštof 15. 10.:
/// „celou další novou sérii, kterou budeme mít jako special series“).
///
/// Pravidla série (zásady B10–B12) -- všechny druhy mixů mají stejnou stavbu:
/// * nahoře obří slovo přes celou šířku (ořízne ho okraj, diakritika celá),
/// * vlevo dole barevný rastrovaný fotoblok, v něm dva řádky faktů,
/// * vpravo „OPENTIFY MMDD“, menší slovo, linka, štítek „ZAMĚŘENÍ / MĚSÍC“
///   a velké číslo (číslo mixu, týden, rok, jinak počet skladeb) -- celé,
/// * černá + krémová + jedna barva mixu,
/// * dlaždice (`compact`) jen slova, blok a číslo.
const _black = Color(0xFF0B0B0B);
const _cream = Color(0xFFF4F1EA);
const _dailyAccents = [
  Color(0xFF1E6FC4), // modrá
  Color(0xFFE2662B), // oranžová
  Color(0xFF2E9E6A), // zelená
  Color(0xFFC8323C), // červená
  Color(0xFFE8B521), // žlutá
  Color(0xFF1C9CA8), // tyrkysová
];
const _months = ['LEDEN', 'ÚNOR', 'BŘEZEN', 'DUBEN', 'KVĚTEN', 'ČERVEN', 'ČERVENEC', 'SRPEN', 'ZÁŘÍ', 'ŘÍJEN', 'LISTOPAD', 'PROSINEC'];

TextStyle _heavy(double size, {double tracking = 0, Color color = _cream, double weight = 900, double width = 70}) => TextStyle(
      fontFamily: 'Archivo',
      fontSize: size,
      fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
      fontVariations: [FontVariation('wght', weight), FontVariation('wdth', width)],
      letterSpacing: size * tracking,
      height: 1,
      color: color,
      decoration: TextDecoration.none,
    );

/// Obsah obalu jednoho druhu mixu.
class _Content {
  const _Content(this.big, this.small, this.number, this.focus, this.lines, this.accent);
  final String big;
  final String small;
  final String number;
  final String focus;
  final List<String> lines;
  final Color accent;
}

int? _int(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt();

String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

Color _accentOf(MixArtSpec spec) => HSLColor.fromAHSL(1, spec.hue, 0.62, 0.5).toColor();

_Content _content(CoverKind kind, MixArtSpec spec) {
  final f = spec.facts ?? const <String, dynamic>{};
  final tracks = _int(f, 'tracks');
  final artists = _int(f, 'artists');
  final trackNo = tracks != null ? '$tracks' : '';
  // Velké číslo = počet skladeb -> dole už jen interpreti (bez opakování).
  final rest = [if (artists != null) '$artists interpretů'];
  final counts = [if (tracks != null) '$tracks skladeb', ...rest];
  switch (kind) {
    case CoverKind.daily:
      final n = int.tryParse(spec.headline) ?? 1;
      // Popisy nesou dva interprety („X, Y a další“) -> vždy dva řádky.
      final names = ((f['artistsLine'] as String?) ?? '')
          .replaceAll(RegExp(r'\s+a další$'), '')
          .split(',')
          .map((a) => a.trim())
          .where((a) => a.isNotEmpty)
          .take(2)
          .toList();
      return _Content('denní', 'mix', '$n', (f['style'] as String?) ?? 'MIX', names, _dailyAccents[(n - 1) % _dailyAccents.length]);
    case CoverKind.discover:
      final week = _int(f, 'week');
      return _Content('objevy', 'týdne', week != null ? '$week' : trackNo, 'PRO TEBE', week != null ? counts : rest, _accentOf(spec));
    case CoverKind.genre:
      return _Content('mix', spec.headline.toLowerCase(), trackNo, 'TVŮJ STYL', rest, _accentOf(spec));
    case CoverKind.mood:
      return _Content('nálada', spec.headline.toLowerCase(), trackNo, 'TVŮJ MIX', rest, _accentOf(spec));
    case CoverKind.year:
      final months = (f['months'] as List<dynamic>?)?.cast<num>();
      final total = months?.fold<num>(0, (a, b) => a + b).toInt();
      final y = spec.headline;
      return _Content('top', 'skladby', '’${y.substring(y.length < 2 ? 0 : y.length - 2)}', 'ROK $y',
          [if (total != null && total > 0) '${_thousands(total)} poslechů', ...counts.take(1)], _accentOf(spec));
    case CoverKind.decade:
      // Dekáda je překvapení k 1. 1. 2027 -- obal existuje, v náhledech se neukazuje.
      final digits = spec.headline.replaceAll(RegExp(r'[^0-9]'), '');
      return _Content('dekáda', 'tvoje', digits.length >= 2 ? digits.substring(digits.length - 2) : digits, 'DEKÁDA', counts,
          _accentOf(spec));
    case CoverKind.onRepeat:
      return _Content('znovu', 'a znovu', trackNo, 'POSLEDNÍ MĚSÍC', rest, _accentOf(spec));
    case CoverKind.throwback:
      return _Content('návrat', 'do minulosti', trackNo, 'ZNOVU OBJEVENO', rest, _accentOf(spec));
    case CoverKind.homeMix:
      return _Content('mix', spec.headline.toLowerCase(), trackNo, 'DOMŮ', rest, _accentOf(spec));
  }
}

/// Velká slova série -- pevná velikost písma podle nejširšího z nich.
const _bigWords = ['denní', 'objevy', 'mix', 'nálada', 'top', 'dekáda', 'znovu', 'návrat'];

/// Jak se sází velké slovo nahoře (rozhodne Kryštof, náhled 15. 10.):
/// * [oneHeight] -- slovo druhu mixu, u všech stejně velké (série v2),
/// * [fillWidth] -- nejvýraznější slovo (styl, nálada, „komunitní“) vždy přesně
///   na šířku obalu jako u Reida Milese; krátká slova obří, dlouhá nižší.
enum BlueNoteLayout { oneHeight, fillWidth }

/// Obal série Blue Note, nebo `null` pro druhy, které ho nemají (stejné jako
/// v2). `today` jen pro testy a náhledy.
Widget? blueNoteCover(MixArtSpec spec, {bool compact = false, DateTime? today, BlueNoteLayout layout = BlueNoteLayout.oneHeight}) {
  final kind = coverKindOf(spec);
  if (kind == null) return null;
  var c = _content(kind, spec);
  if (layout == BlueNoteLayout.fillWidth) {
    // Nahoru slovo, které je vidět hned; „mix“ / „nálada“ doprava.
    switch (kind) {
      case CoverKind.genre:
        c = _Content(c.small, 'mix', c.number, c.focus, c.lines, c.accent);
      case CoverKind.mood:
        c = _Content(c.small, 'nálada', c.number, c.focus, c.lines, c.accent);
      case CoverKind.homeMix:
        final words = c.small.split(' ');
        c = _Content(words.first, words.length > 1 ? words.skip(1).join(' ') : 'mix', c.number, c.focus, c.lines, c.accent);
      default:
        break;
    }
  }
  return _BlueNote(spec: spec, c: c, tile: compact, today: today ?? DateTime.now(), layout: layout);
}

class _BlueNote extends StatelessWidget {
  const _BlueNote({required this.spec, required this.c, required this.tile, required this.today, required this.layout});

  final MixArtSpec spec;
  final _Content c;
  final bool tile;
  final DateTime today;
  final BlueNoteLayout layout;

  @override
  Widget build(BuildContext context) {
    final facts = spec.facts ?? const <String, dynamic>{};
    final photos = ((facts['photos'] as List<dynamic>?)?.cast<String>() ?? const <String>[]).isNotEmpty
        ? (facts['photos'] as List<dynamic>).cast<String>()
        : spec.photos;
    return LayoutBuilder(builder: (context, box) {
      final s = box.biggest.shortestSide;
      final block = Rect.fromLTWH(0, s * 0.441, s * 0.665, s * 0.559);
      return ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: _black),
          Positioned.fromRect(rect: block, child: ColoredBox(color: c.accent)),
          if (photos.isNotEmpty)
            Positioned.fromRect(
              rect: block,
              child: ColorFiltered(
                colorFilter: _duotone(_black, c.accent),
                child: ArtworkImage(url: photos.first, icon: Symbols.person_rounded, iconSize: 18),
              ),
            ),
          Positioned.fromRect(rect: block, child: const CustomPaint(painter: _HalftonePainter())),
          CustomPaint(
            painter: _TypePainter(
              c: c,
              month: _months[today.month - 1],
              stamp: 'OPENTIFY ${today.month.toString().padLeft(2, '0')}${today.day.toString().padLeft(2, '0')}',
              small: tile,
              layout: layout,
            ),
          ),
          const IgnorePointer(child: CustomPaint(painter: GrainPainter())),
        ]),
      );
    });
  }
}

/// Fotka ve dvou barvách: černá -> barva mixu.
ColorFilter _duotone(Color dark, Color light) {
  List<double> row(double d, double l) {
    final k = (l - d) * 1.4;
    return [k * 0.3, k * 0.59, k * 0.11, 0, (d - (l - d) * 0.15) * 255];
  }

  return ColorFilter.matrix([...row(dark.r, light.r), ...row(dark.g, light.g), ...row(dark.b, light.b), 0, 0, 0, 1, 0]);
}

/// Svislý tiskový rastr: proužky sílí od světlého středu k okrajům.
class _HalftonePainter extends CustomPainter {
  const _HalftonePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.shortestSide / 70;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(0.24, -0.2),
        radius: 0.9,
        colors: [Color(0x00000000), Color(0x660B0B0B), Color(0xE60B0B0B)],
        stops: [0, 0.6, 1],
      ).createShader(rect);
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawRect(Rect.fromLTWH(x, 0, step * 0.55, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_HalftonePainter old) => false;
}

class _TypePainter extends CustomPainter {
  _TypePainter({required this.c, required this.month, required this.stamp, required this.small, required this.layout});

  final _Content c;
  final String month;
  final String stamp;
  final bool small;
  final BlueNoteLayout layout;

  TextPainter _layout(String text, TextStyle style) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();

  /// Text s účařím v `baseline` (zlomek strany); `maxWidth` ho zmenší, aby se vešel.
  void _text(Canvas canvas, double s, String text, TextStyle style, double x, double baseline, {double? maxWidth}) {
    var tp = _layout(text, style);
    if (maxWidth != null && tp.width > maxWidth) {
      final k = maxWidth / tp.width;
      tp = _layout(text, style.copyWith(fontSize: style.fontSize! * k, letterSpacing: style.letterSpacing! * k));
    }
    tp.paint(canvas, Offset(x, s * baseline - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
  }

  /// Text zkrácený „…“, aby písmo při zmenšení nekleslo pod `minScale`.
  String _shorten(String text, TextStyle style, double width, double minScale) {
    if (_layout(text, style).width * minScale <= width) return text;
    var t = text;
    while (t.length > 4 && _layout('$t…', style).width * minScale > width) {
      t = t.substring(0, t.length - 1);
    }
    return '${t.trimRight()}…';
  }

  /// Slova rozdělená do nejvýš dvou řádků šířky `width`; příliš široké slovo
  /// se nejdřív zúží řezem, teprve pak zmenší.
  List<String> _wrap(String text, TextStyle style, double width) {
    // Zalomit jde i za lomítkem („alternativa/ indie“).
    final words = text.replaceAll('/', '/ ').split(' ').where((w) => w.isNotEmpty).toList();
    final lines = <String>[];
    var cur = '';
    for (final w in words) {
      final next = cur.isEmpty ? w : (cur.endsWith('/') ? '$cur$w' : '$cur $w');
      if (cur.isNotEmpty && _layout(next, style).width > width && lines.isEmpty) {
        lines.add(cur);
        cur = w;
      } else {
        cur = next;
      }
    }
    lines.add(cur);
    return lines;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    // Velké slovo: u všech obalů stejná velikost, poloha i účaří, bez ořezu
    // (Okoun 15. 10., zásada B10). Účaří nechává místo dolním dotahům.
    final base = _heavy(s * 0.4, tracking: -0.05, width: 100);
    final widest = _bigWords.map((w) => _layout(w, base).width).reduce((a, b) => a > b ? a : b);
    var k = s * 0.94 / widest;
    var baseline = 0.335;
    if (layout == BlueNoteLayout.fillWidth) {
      // Přesně na šířku (stejné okraje vlevo i vpravo), účaří těsně nad blokem;
      // výška nejvýš po horní okraj, ať čárky zůstanou celé.
      final tp = _layout(c.big, base);
      k = s * 0.94 / tp.width;
      final ascent = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      final maxK = s * 0.39 / ascent;
      if (k > maxK) k = maxK;
      baseline = 0.42;
    }
    _text(canvas, s, c.big, base.copyWith(fontSize: base.fontSize! * k, letterSpacing: base.letterSpacing! * k), s * 0.03, baseline);
    // Menší slovo vpravo: jedna velikost, dlouhé se zalomí do dvou řádků.
    // Menší slovo vpravo: jedna velikost a jeden (zúžený) řez pro všechny;
    // dlouhé se zalomí, jen nezalomitelné slovo se zmenší.
    final smallStyle = _heavy(s * 0.075, tracking: -0.02, width: 75);
    final lines = _wrap(c.small, smallStyle, s * 0.29);
    for (var i = 0; i < lines.length; i++) {
      final y = 0.585 - (lines.length - 1 - i) * 0.068;
      _text(canvas, s, lines[i], smallStyle, s * 0.684, y, maxWidth: s * 0.29);
    }
    // Číslo celé, s okrajem nad spodní hranou (zásada B11); dlouhé se zúží.
    _text(canvas, s, c.number, _heavy(s * 0.42, tracking: -0.04, color: c.accent, width: 80), s * 0.675, 0.935, maxWidth: s * 0.3);
    if (small) return;
    canvas.drawRect(Rect.fromLTWH(s * 0.688, s * 0.603, s * 0.282, s * 0.006), Paint()..color = _cream);
    // Ve variantě na šířku slovo sahá až k bloku -- razítko by se překrylo.
    if (layout == BlueNoteLayout.oneHeight) _text(canvas, s, stamp, _heavy(s * 0.024, tracking: 0.18, weight: 600), s * 0.688, 0.425);
    final focus = _heavy(s * 0.03, tracking: 0.12, weight: 700);
    _text(canvas, s, _shorten(c.focus.toUpperCase(), focus, s * 0.29, 0.7), focus, s * 0.688, 0.642, maxWidth: s * 0.29);
    _text(canvas, s, month, _heavy(s * 0.024, tracking: 0.18, weight: 500), s * 0.688, 0.675);
    final lineStyle = _heavy(s * 0.031, tracking: 0.2, weight: 700);
    for (var i = 0; i < c.lines.length; i++) {
      final y = 0.935 - (c.lines.length - 1 - i) * 0.042;
      _text(canvas, s, c.lines[i].toUpperCase(), lineStyle, s * 0.035, y, maxWidth: s * 0.6);
    }
  }

  @override
  bool shouldRepaint(_TypePainter old) => old.c != c || old.small != small || old.month != month || old.layout != layout;
}
