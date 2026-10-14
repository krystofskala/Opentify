import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'media_card.dart' show ArtworkImage;
import 'mix_artwork.dart' show GrainPainter, MixArtSpec;

/// Speciální edice obalů Denních mixů ve stylu Blue Note / Reida Milese
/// (15. 10., návrh 8c-BN, vzor `claude/design/vzory/blue-note-denni-mix.html`).
/// Vedle obalů v2, ne místo nich.
///
/// Pravidla série (zásady B10–B12):
/// * všechny obaly stejná stavba: obří „denní“ ořezané okrajem, barevný
///   rastrovaný fotoblok vlevo dole, vpravo „mix“, linka, štítek a číslo,
/// * štítek vždy „ZAMĚŘENÍ · MĚSÍC“, nad ním „OPENTIFY MMDD“,
/// * číslo celé uvnitř obalu,
/// * dvoubarevnost: černá + krémová + jedna barva mixu.
const _black = Color(0xFF0B0B0B);
const _cream = Color(0xFFF4F1EA);
const _accents = [
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

/// Obal Denního mixu v edici Blue Note; `today` jen pro testy a náhledy.
Widget blueNoteDailyCover(MixArtSpec spec, {bool compact = false, DateTime? today}) =>
    _BlueNoteDaily(spec: spec, tile: compact, today: today ?? DateTime.now());

class _BlueNoteDaily extends StatelessWidget {
  const _BlueNoteDaily({required this.spec, required this.tile, required this.today});

  final MixArtSpec spec;
  final bool tile;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(spec.headline) ?? 1;
    final accent = _accents[(n - 1) % _accents.length];
    final facts = spec.facts ?? const <String, dynamic>{};
    final photos = ((facts['photos'] as List<dynamic>?)?.cast<String>() ?? const <String>[]).isNotEmpty
        ? (facts['photos'] as List<dynamic>).cast<String>()
        : spec.photos;
    final style = facts['style'] as String?;
    final artists = ((facts['artistsLine'] as String?) ?? '')
        .replaceAll(RegExp(r'\s+a další$'), '')
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .take(3)
        .toList();
    // Série má vždy tři řádky interpretů (zásada B10); kratší seznam doplní „a další“.
    if (artists.isNotEmpty && artists.length < 3) artists.add('a další');
    return LayoutBuilder(builder: (context, c) {
      final s = c.biggest.shortestSide;
      final block = Rect.fromLTWH(0, s * 0.441, s * 0.665, s * 0.559);
      return ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: _black),
          Positioned.fromRect(rect: block, child: ColoredBox(color: accent)),
          if (photos.isNotEmpty)
            Positioned.fromRect(
              rect: block,
              child: ColorFiltered(
                colorFilter: _duotone(_black, accent),
                child: ArtworkImage(url: photos.first, icon: Symbols.person_rounded, iconSize: 18),
              ),
            ),
          Positioned.fromRect(rect: block, child: const CustomPaint(painter: _HalftonePainter())),
          CustomPaint(
            painter: _TypePainter(
              n: n,
              accent: accent,
              label: '${(style ?? 'MIX').toUpperCase()} · ${_months[today.month - 1]}',
              stamp: 'OPENTIFY ${today.month.toString().padLeft(2, '0')}${today.day.toString().padLeft(2, '0')}',
              artists: tile ? const [] : artists.map((a) => a.toUpperCase()).toList(),
              small: tile,
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
  _TypePainter({required this.n, required this.accent, required this.label, required this.stamp, required this.artists, required this.small});

  final int n;
  final Color accent;
  final String label;
  final String stamp;
  final List<String> artists;
  final bool small;

  /// Text s účařím v `baseline` (zlomek strany).
  double _text(Canvas canvas, double s, String text, TextStyle style, double x, double baseline, {double? fitWidth}) {
    var tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    if (fitWidth != null && tp.width > 0) {
      final scaled = style.copyWith(fontSize: style.fontSize! * fitWidth / tp.width, letterSpacing: style.letterSpacing! * fitWidth / tp.width);
      tp = TextPainter(text: TextSpan(text: text, style: scaled), textDirection: TextDirection.ltr)..layout();
    }
    final asc = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    tp.paint(canvas, Offset(x, s * baseline - asc));
    return tp.width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    // „denní“ přes celou šířku, levý okraj ořízne první písmeno.
    // Čárka nad í musí zůstat celá (náhled v1: useknutá, četlo se „denni“).
    _text(canvas, s, 'denní', _heavy(s * 0.4, tracking: -0.05, width: 100), -s * 0.03, 0.4, fitWidth: s * 1.0);
    _text(canvas, s, 'mix', _heavy(s * 0.14, tracking: -0.05, width: 100), s * 0.682, 0.585);
    // Číslo celé: účaří nad spodní hranou (zásada B11).
    _text(canvas, s, '$n', _heavy(s * 0.42, tracking: -0.04, color: accent, width: 80), s * 0.675, 0.935);
    if (small) return;
    canvas.drawRect(Rect.fromLTWH(s * 0.688, s * 0.603, s * 0.282, s * 0.006), Paint()..color = _cream);
    _text(canvas, s, stamp, _heavy(s * 0.024, tracking: 0.18, weight: 600), s * 0.688, 0.468);
    // Štítek ve dvou řádcích: zaměření / měsíc; dlouhé zaměření se zúží jen do míry.
    final parts = label.split(' · ');
    final focus = _heavy(s * 0.03, tracking: 0.12, weight: 700);
    final fp = TextPainter(text: TextSpan(text: parts.first, style: focus), textDirection: TextDirection.ltr)..layout();
    var line = parts.first;
    var fit = fp.width > s * 0.29 ? s * 0.29 : null;
    if (fit != null && fit / fp.width < 0.7) {
      // příliš dlouhé -> zkrátit, ať písmo není drobné
      while (line.length > 4) {
        line = line.substring(0, line.length - 1);
        final t = TextPainter(text: TextSpan(text: '$line…', style: focus), textDirection: TextDirection.ltr)..layout();
        if (t.width * 0.7 <= s * 0.29) break;
      }
      line = '${line.trimRight()}…';
      final t = TextPainter(text: TextSpan(text: line, style: focus), textDirection: TextDirection.ltr)..layout();
      fit = t.width > s * 0.29 ? s * 0.29 : null;
    }
    _text(canvas, s, line, focus, s * 0.688, 0.642, fitWidth: fit);
    if (parts.length > 1) _text(canvas, s, parts.last, _heavy(s * 0.024, tracking: 0.18, weight: 500), s * 0.688, 0.675);
    for (var i = 0; i < artists.length; i++) {
      final y = 0.935 - (artists.length - 1 - i) * 0.042;
      final st = _heavy(s * 0.031, tracking: 0.2, weight: 700);
      final p = TextPainter(text: TextSpan(text: artists[i], style: st), textDirection: TextDirection.ltr)..layout();
      _text(canvas, s, artists[i], st, s * 0.035, y, fitWidth: p.width > s * 0.6 ? s * 0.6 : null);
    }
  }

  @override
  bool shouldRepaint(_TypePainter old) => old.n != n || old.label != label || old.artists != artists || old.small != small;
}
