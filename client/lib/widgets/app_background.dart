import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Globální pozadí appky -- inspirováno "chroma grainy gradient" texturami
/// (youworkforthem.com/graphic/E7830), ne plochou barvou:
///   - `isMulti` (žádná obrazovka právě neurčuje barvu -- Domů/Hledání/
///     Knihovna/Profil, viz `activeScreenAccentProvider` v `app.dart`) ->
///     gradient složený z více odstínů okolo `seed`u ("všechny barvy").
///   - jakmile obrazovka (Album/Interpret) barvu určí -> zredukuje se na
///     dvoubarevný monochromatický gradient jednoho odstínu -- barvy
///     "zmizí", jak žádal uživatel.
///   - zrno navrch pomáhá přechod mezi těmahle stavy (a mezi skladbami)
///     opticky zjemnit, není to jen dekorace.
///   - jemné vlnění gradientu (posun `Alignment`u) -- pomalé v klidu,
///     znatelně rychlejší, když hraje hudba, a krátce zrychlí při scrollu
///     (kdekoliv v appce -- `NotificationListener<ScrollNotification>`
///     zachytává bubliny ze všech potomků, ne jen jedné konkrétní obrazovky).
class AppBackground extends StatefulWidget {
  const AppBackground({
    super.key,
    required this.seed,
    required this.brightness,
    required this.isMulti,
    required this.isPlaying,
    required this.child,
  });

  final Color seed;
  final Brightness brightness;
  final bool isMulti;
  final bool isPlaying;
  final Widget child;

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _phase = ValueNotifier(0);
  Duration _lastElapsed = Duration.zero;
  double _scrollBoost = 0;

  @override
  void initState() {
    super.initState();
    // Vlastní `Ticker`, ne `AnimationController` -- potřebujeme surové `dt`
    // mezi snímky pro plynulý útlum `_scrollBoost`u, ne jen zacyklenou
    // hodnotu 0..1. Mění jen `_phase` (ValueNotifier), NE `setState` na
    // celém stromu -- `widget.child` je celá appka pod routerem, běžet by na
    // ní muselo přemalovávat 60x/s úplně všechno.
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0 || dt > 0.25) return; // první tik / karta byla na pozadí -- přeskočit skok

    // Skoro klid, když nic nehraje a nescrolluje se -- znatelně živější
    // vlnění během přehrávání, jak žádal uživatel.
    final baseSpeed = widget.isPlaying ? 0.45 : 0.06;
    _scrollBoost = (_scrollBoost - dt * 1.4).clamp(0, 4);
    _phase.value += dt * (baseSpeed + _scrollBoost);
  }

  void _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final delta = (notification.scrollDelta ?? 0).abs();
      _scrollBoost = (_scrollBoost + delta * 0.015).clamp(0, 4);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(widget.seed);
    final saturation = hsl.saturation.clamp(0.38, 0.62);
    final isDark = widget.brightness == Brightness.dark;
    final baseLightness = isDark ? 0.14 : 0.94;

    final List<Color> colors;
    if (widget.isMulti) {
      // "Všechny barvy" -- rotace odstínu o čtyři kroky okolo seedu, ne
      // jedna plochá fialová. Reálná extrakce palety z viditelných obalů na
      // Domů by vyžadovala novou infrastrukturu (analyzovat N obrázků
      // najednou) -- tohle je stylizovaná náhrada se stejným efektem
      // "vícebarevnosti", ne doslovný výtah z aktuálně vykreslených karet.
      colors = [0, 85, 170, 255]
          .map((hueOffset) => hsl
              .withHue((hsl.hue + hueOffset) % 360)
              .withSaturation(saturation)
              .withLightness(baseLightness + (isDark ? 0.05 : -0.03))
              .toColor())
          .toList();
    } else {
      colors = [
        hsl.withSaturation(saturation).withLightness(baseLightness).toColor(),
        hsl
            .withHue((hsl.hue + 26) % 360)
            .withSaturation(saturation)
            .withLightness(baseLightness + (isDark ? 0.09 : -0.07))
            .toColor(),
      ];
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        _onScroll(notification);
        return false;
      },
      child: ValueListenableBuilder<double>(
        valueListenable: _phase,
        // `child` (celá appka) se postaví jen JEDNOU a znovupoužívá při
        // každém tiku -- animuje se jen gradient/zrno níž, ne obsah appky.
        child: widget.child,
        builder: (context, phase, staticChild) {
          final wobbleX = 0.14 * sin(phase);
          final wobbleY = 0.14 * cos(phase * 0.82);
          return Stack(
            fit: StackFit.expand,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeInOut,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1 + wobbleX, -1 + wobbleY),
                    end: Alignment(1 - wobbleY, 1 - wobbleX),
                    colors: colors,
                  ),
                ),
              ),
              RepaintBoundary(
                child: CustomPaint(painter: _BlobPainter(colors: colors, brightness: widget.brightness)),
              ),
              // Přímé dítě `Stack`u (`fit: StackFit.expand` ho samo natáhne
              // na celou plochu) -- `Positioned.fill` zabalené v
              // `RepaintBoundary` shazovalo appku (release-only pád):
              // `Positioned` potřebuje být přímý potomek `Stack`u, jinak
              // aplikuje `StackParentData` na špatný `RenderObject`.
              const RepaintBoundary(
                child: IgnorePointer(child: CustomPaint(painter: _GrainPainter())),
              ),
              staticChild!,
            ],
          );
        },
      ),
    );
  }
}

/// Velké měkké rozmazané "kaňky" v paletových barvách -- referenční "chroma
/// grainy gradient" vzhled má hloubku z překrývajících se barevných skvrn,
/// ne z jedné hladké roviny. Přepočítá se jen když se změní paleta (barva
/// obrazovky/skladby), ne každý snímek -- `shouldRepaint` to hlídá.
class _BlobPainter extends CustomPainter {
  const _BlobPainter({required this.colors, required this.brightness});

  final List<Color> colors;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(colors.first.toARGB32());
    const blobCount = 7;
    for (var i = 0; i < blobCount; i++) {
      final color = colors[i % colors.length];
      final radius = size.shortestSide * (0.25 + random.nextDouble() * 0.35);
      final center = Offset(random.nextDouble() * size.width, random.nextDouble() * size.height);
      final paint = Paint()
        ..color = color.withValues(alpha: brightness == Brightness.dark ? 0.16 : 0.14)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.5);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BlobPainter oldDelegate) =>
      !listEquals(oldDelegate.colors, colors) || oldDelegate.brightness != brightness;
}

/// Statické filmové zrno -- vykreslené jednou při prvním layoutu
/// (`shouldRepaint` vždy `false`), hustší a viditelnější než dřívější první
/// pokus (referenční "chroma grainy" textura je znatelná, ne jemný nádech).
class _GrainPainter extends CustomPainter {
  const _GrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(7);
    final total = (size.width * size.height / 480).round().clamp(800, 14000);
    final lightPoints = <double>[];
    final darkPoints = <double>[];
    for (var i = 0; i < total; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      if (random.nextBool()) {
        lightPoints
          ..add(x)
          ..add(y);
      } else {
        darkPoints
          ..add(x)
          ..add(y);
      }
    }
    final paint = Paint()
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(lightPoints),
      paint..color = Colors.white.withValues(alpha: 0.07),
    );
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(darkPoints),
      paint..color = Colors.black.withValues(alpha: 0.07),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
