import 'dart:math' as math;
import 'dart:ui';

import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';

import '../state/glass_settings.dart';
import '../theme/app_theme.dart' show buildAppTheme;
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import 'glass/glass_rim.dart';
import 'glass/liquid_glass.dart';
import 'mix_artwork.dart' show GrainPainter;

/// Liquid Glass materiál (viz pravidla v `theme/glass_tokens.dart`):
/// rozmazání + vibrance (sytost/jas obsahu ZA sklem), NEUTRÁLNÍ výplň,
/// vlasová přechodová hrana + 1px lesk horní hrany, plynulé (squircle) rohy
/// a volitelně jeden měkký stín pro plovoucí prvky.
///
/// Jen pro plovoucí vrstvu (tab bar, mini přehrávač, vyhledávání v liště,
/// sheety, menu, panel návrhů) -- NE pro obsah (karty, řádky, čipy).
/// `blur: false` = stejný vzhled bez `BackdropFilter`, pro panely ležící na
/// už rozmazaném skle (sklo na skle se dvěma rozmazáními je zakázané).
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.lg)),
    this.blurSigma = GlassTokens.blur,
    this.saturation = GlassTokens.vibrancy,
    this.tint,
    this.tintOpacity = GlassTokens.playerTint,
    this.padding,
    this.showEdgeHighlight = true,
    this.blur = true,
    this.shadow = false,
    this.frost = 0,
    this.emphasis = 0,
    this.baseFill = true,
    this.fit = StackFit.loose,
    this.rim = false,
    this.liquid = false,
  });

  /// Hustě namrzlé sklo přehrávače: silné rozmazání + vibrance, jemné
  /// tónování barvou skladby a mléčný závoj. Za ním je živé pozadí appky.
  const GlassContainer.frosted({
    super.key,
    required this.child,
    required Color this.tint,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.lg)),
    this.blurSigma = GlassTokens.blurPlayer,
    this.padding,
    this.shadow = false,
    this.showEdgeHighlight = true,
    this.fit = StackFit.loose,
    this.rim = false,
    this.liquid = false,
  })  : saturation = GlassTokens.vibrancy,
        tintOpacity = GlassTokens.playerTint,
        blur = true,
        frost = 0.06,
        emphasis = 0,
        baseFill = true;

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double saturation;

  /// Tónování barvou -- JEN plochy přehrávače (barva skladby). Chrome
  /// (navigace, vyhledávání, sheety) zůstává neutrální.
  final Color? tint;
  final double tintOpacity;
  final EdgeInsetsGeometry? padding;
  final bool showEdgeHighlight;
  final bool blur;

  /// Měkký stín -- jen plovoucí prvky (tab bar, mini přehrávač, návrhy).
  final bool shadow;

  /// Mléčný bílý závoj navíc (0 = žádný).
  final double frost;

  /// Bílá navíc pro "zvýrazněnou" kapsli (vybraný tab/segment).
  final double emphasis;

  /// `false` = bez neutrální výplně (jen hrana + zvýraznění) -- vnořené
  /// kapsle na skle.
  final bool baseFill;
  final StackFit fit;

  /// Lem v barvě obsahu pod sklem (`GlassRim`) -- plovoucí prvky (tab bar,
  /// mini přehrávač, ovládání přehrávače, skleněná tlačítka).
  final bool rim;

  /// Sklo se skutečným lomem obsahu pod sebou (`LiquidGlass`, test) --
  /// jen uvnitř `LiquidScope` a se zapnutým "Lom skla (test)".
  final bool liquid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeDark = theme.brightness == Brightness.dark;
    final shape = glassShape(borderRadius);
    // Profil › Vzhled: "Mléčnost skla" (rozmazání), "Tón skla" (výplň)
    // a "Tón v barvě skladby" (barva výplně místo šedé/bílé).
    final settings = GlassSettings.maybeOf(context);
    // Světlé/tmavé sklo nezávisle na motivu appky (Profil › Vzhled › Tón skla).
    final isDark = switch (settings?.tone ?? GlassToneMode.auto) {
      GlassToneMode.auto => themeDark,
      GlassToneMode.light => false,
      GlassToneMode.dark => true,
    };
    final veil = 2 * (settings?.tint ?? 0.5);
    double a(double alpha) => (alpha * veil).clamp(0.0, 0.95);
    final base = switch (settings?.tintColor) {
      final c? => _accentTone(c, isDark),
      null => isDark ? GlassTokens.fillDarkColor : Colors.white,
    };

    final fills = <Color>[
      if (baseFill) base.withValues(alpha: a(isDark ? GlassTokens.fillDark : GlassTokens.fillLight)),
      if (tint != null) tint!.withValues(alpha: a(tintOpacity)),
      if (frost > 0) Colors.white.withValues(alpha: a(frost)),
      if (emphasis > 0) Colors.white.withValues(alpha: emphasis),
    ];
    final fill = _flatten(fills);
    Widget content = padding == null ? child : Padding(padding: padding!, child: child);
    // Sklo opačné než motiv: obsah na něm dostane motiv jeho jasu, ať text
    // a ikony zůstanou čitelné (bílá na světlém skle by zmizela).
    if (baseFill && isDark != themeDark) {
      final flipped = _themeFor(theme.colorScheme.primary, isDark ? Brightness.dark : Brightness.light);
      content = Theme(
        data: flipped,
        child: DefaultTextStyle.merge(
          style: TextStyle(color: flipped.colorScheme.onSurface),
          child: IconTheme.merge(data: IconThemeData(color: flipped.colorScheme.onSurface), child: content),
        ),
      );
    }
    final liquidCapture = liquid && (GlassSettings.maybeOf(context)?.liquid ?? false) ? LiquidScope.maybeOf(context) : null;
    // Profil › Vzhled › "Zrno na skle": jemná textura nad výplní, pod obsahem.
    if (settings?.grain ?? false) {
      content = Stack(
        fit: fit,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: (settings?.fineGrain ?? false) ? 0.3 : 0.55,
                child: const RepaintBoundary(child: CustomPaint(painter: GrainPainter())),
              ),
            ),
          ),
          content,
        ],
      );
    }
    final Widget surface = DecoratedBox(
      decoration: ShapeDecoration(shape: shape, color: fill),
      child: content,
    );
    final sigma = blur ? blurSigma * 2 * (settings?.frost ?? 0.5) : 0.0;
    // Vibrance (`outer`) se aplikuje na výsledek rozmazání (`inner`) --
    // stejné pořadí jako CSS `backdrop-filter: blur() saturate()`.
    ImageFilter frosted() => ImageFilter.compose(
          outer: vibrancyColorFilter(saturation: saturation),
          inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        );

    final glass = ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: Stack(
        fit: fit,
        children: [
          if (liquidCapture != null) ...[
            // Lom, rozmazání, výplň i lem kreslí shader nad zachyceným obsahem.
            Positioned.fill(
              child: LiquidGlass(
                capture: liquidCapture,
                radius: borderRadius.topLeft.x,
                blurSigma: sigma,
                fill: fill ?? const Color(0x00000000),
                saturation: saturation,
              ),
            ),
            content,
          ] else if (rim) ...[
            // Lem čte ostrý obsah pod hranou; rozmazání je až za ním.
            Positioned.fill(child: GlassRim(borderRadius: borderRadius)),
            if (blur)
              Positioned.fill(
                child: ClipRRect(
                  clipper: _InnerClipper(borderRadius, GlassRim.width),
                  child: BackdropFilter(filter: frosted(), child: const SizedBox.expand()),
                ),
              ),
            surface,
          ] else if (blur)
            BackdropFilter(filter: frosted(), child: surface)
          else
            surface,
          // Sklo s lomem si odlesk kreslí samo (pohyblivý podle obsahu).
          if (showEdgeHighlight && liquidCapture == null)
            Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: GlassEdgePainter(shape: shape))),
            ),
        ],
      ),
    );

    return RepaintBoundary(
      child: shadow
          ? DecoratedBox(
              decoration: ShapeDecoration(shape: shape, shadows: glassShadow),
              child: glass,
            )
          : glass,
    );
  }

  static final Map<(Color, Brightness), ThemeData> _flippedThemes = {};

  static ThemeData _themeFor(Color seed, Brightness brightness) {
    // Během přebarvení (2,8 s) je `primary` každý snímek jiná barva -- bez
    // zaokrouhlení se celý motiv (`ColorScheme.fromSeed`) počítal znovu pro
    // každé sklo v každém snímku. 16 stupňů na kanál: pár motivů na přechod,
    // rozdíl v tónu textu okem nepoznat.
    int q(double v) => ((v * 15).round() * 17);
    final key = Color.fromARGB(255, q(seed.r), q(seed.g), q(seed.b));
    if (_flippedThemes.length > 48) _flippedThemes.clear();
    return _flippedThemes.putIfAbsent((key, brightness), () => buildAppTheme(seed: key, brightness: brightness));
  }

  /// Tón skla v barvě skladby: tmavý odstín v tmavém režimu, světlý ve
  /// světlém (čitelnost textu jako u neutrální výplně).
  static Color _accentTone(Color c, bool isDark) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withSaturation((hsl.saturation * (isDark ? 0.7 : 0.55)).clamp(0.0, 1.0))
        .withLightness(isDark ? 0.17 : 0.9)
        .toColor();
  }

  static Color? _flatten(List<Color> layers) {
    if (layers.isEmpty) return null;
    return layers.skip(1).fold<Color>(layers.first, (under, over) => Color.alphaBlend(over, under));
  }
}

/// Vnitřek skla bez pruhu s lomem (zaoblený obdélník zmenšený o `inset`).
class _InnerClipper extends CustomClipper<RRect> {
  const _InnerClipper(this.radius, this.inset);

  final BorderRadius radius;
  final double inset;

  @override
  RRect getClip(Size size) {
    final i = math.min(inset, size.shortestSide / 2);
    Radius r(Radius c) => Radius.circular(math.max(0.0, c.x - i));
    return RRect.fromRectAndCorners(
      (Offset.zero & size).deflate(i),
      topLeft: r(radius.topLeft),
      topRight: r(radius.topRight),
      bottomLeft: r(radius.bottomLeft),
      bottomRight: r(radius.bottomRight),
    );
  }

  @override
  bool shouldReclip(_InnerClipper old) => old.radius != radius || old.inset != inset;
}

/// Jediný měkký stín plovoucích prvků (`GlassTokens.shadow*`).
const List<BoxShadow> glassShadow = [
  BoxShadow(
    color: Color.fromRGBO(0, 0, 0, GlassTokens.shadowAlpha),
    blurRadius: GlassTokens.shadowBlur,
    offset: Offset(0, GlassTokens.shadowOffsetY),
  ),
];

/// Squircle tvar z běžného `BorderRadius` (plynulé rohy, HIG/iOS styl).
SmoothRectangleBorder glassShape(BorderRadius radius) {
  SmoothRadius r(Radius corner) =>
      SmoothRadius(cornerRadius: corner.x, cornerSmoothing: corner.x == 0 ? 0 : GlassTokens.smoothing);
  return SmoothRectangleBorder(
    borderRadius: SmoothBorderRadius.only(
      topLeft: r(radius.topLeft),
      topRight: r(radius.topRight),
      bottomLeft: r(radius.bottomLeft),
      bottomRight: r(radius.bottomRight),
    ),
  );
}

/// Přirozený odlesk skla: JEDNA tenká linka po obvodu, jejíž jas závisí na
/// tom, kam hrana míří vůči světlu (shora zleva) -- zaoblené konce a rohy
/// natočené ke světlu svítí, rovné hrany skoro vůbec, protější strana jen
/// slabý odraz. Dřív obvodová vlasová linka + druhá linka lesku nahoře
/// působily jako falešná dvojitá čára (živě nahlášeno, mobil i PC).
class GlassEdgePainter extends CustomPainter {
  const GlassEdgePainter({required this.shape});

  final ShapeBorder shape;

  // Směr ke světlu (shora zleva), jednotkový.
  static const double _lx = -0.6, _ly = -0.8;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect.deflate(0.5));
    final paint = Paint()
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    for (final metric in path.computeMetrics()) {
      const step = 2.0;
      for (var d = 0.0; d < metric.length; d += step) {
        final a = metric.getTangentForOffset(d);
        final b = metric.getTangentForOffset(math.min(metric.length, d + step));
        if (a == null || b == null) continue;
        // Obrys jde po směru hodinových ručiček -> vnější normála = (ty, -tx).
        final nx = a.vector.dy, ny = -a.vector.dx;
        final facing = nx * _lx + ny * _ly;
        final light = math.pow(math.max(0.0, facing), 6) * GlassTokens.edgeAlphaStart +
            math.pow(math.max(0.0, -facing), 6) * GlassTokens.edgeAlphaEnd;
        if (light < 0.01) continue;
        paint.color = Colors.white.withValues(alpha: light.toDouble());
        canvas.drawLine(a.position, b.position, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant GlassEdgePainter oldDelegate) => oldDelegate.shape != shape;
}
