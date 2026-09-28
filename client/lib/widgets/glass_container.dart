import 'dart:ui';

import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shape = glassShape(borderRadius);

    final fills = <Color>[
      if (baseFill && isDark) Colors.black.withValues(alpha: GlassTokens.fillDark),
      if (baseFill && isDark) Colors.white.withValues(alpha: GlassTokens.fillDarkWhiteHint),
      if (baseFill && !isDark) Colors.white.withValues(alpha: GlassTokens.fillLight),
      if (tint != null) tint!.withValues(alpha: tintOpacity),
      if (frost > 0) Colors.white.withValues(alpha: frost),
      if (emphasis > 0) Colors.white.withValues(alpha: emphasis),
    ];
    Widget surface = DecoratedBox(
      decoration: ShapeDecoration(shape: shape, color: _flatten(fills)),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    final glass = ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: Stack(
        fit: fit,
        children: [
          if (blur)
            BackdropFilter(
              // Vibrance (`outer`) se aplikuje na výsledek rozmazání (`inner`)
              // -- stejné pořadí jako CSS `backdrop-filter: blur() saturate()`.
              filter: ImageFilter.compose(
                outer: vibrancyColorFilter(saturation: saturation),
                inner: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              ),
              child: surface,
            )
          else
            surface,
          if (showEdgeHighlight)
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

  static Color? _flatten(List<Color> layers) {
    if (layers.isEmpty) return null;
    return layers.skip(1).fold<Color>(layers.first, (under, over) => Color.alphaBlend(over, under));
  }
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

/// Vlasová přechodová hrana (vlevo nahoře světlejší → vpravo dole skoro
/// nic) + 1px vnitřní lesk podél horní hrany. Tohle z plochy dělá sklo.
class GlassEdgePainter extends CustomPainter {
  const GlassEdgePainter({required this.shape});

  final ShapeBorder shape;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outer = shape.getOuterPath(rect.deflate(GlassTokens.edgeWidth / 2));
    canvas.drawPath(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = GlassTokens.edgeWidth
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: GlassTokens.edgeAlphaStart),
            Colors.white.withValues(alpha: GlassTokens.edgeAlphaEnd),
          ],
        ).createShader(rect),
    );
    // Lesk jen v horní části -- klip na horních ~35 % výšky.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height * 0.35));
    canvas.drawPath(
      shape.getOuterPath(rect.deflate(1.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: GlassTokens.topHighlightAlpha),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.35)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GlassEdgePainter oldDelegate) => oldDelegate.shape != shape;
}

/// Pozadí `AppBar`u, které se ze skla objeví, až když pod ním obsah
/// odscrolluje (stejná logika jako `AppBar.scrolledUnder`) -- v klidu je
/// lišta průhledná. HIG Materials: horní lišta je součást plovoucí vrstvy.
class GlassScrolledUnderBackground extends StatefulWidget {
  const GlassScrolledUnderBackground({super.key});

  @override
  State<GlassScrolledUnderBackground> createState() => _GlassScrolledUnderBackgroundState();
}

class _GlassScrolledUnderBackgroundState extends State<GlassScrolledUnderBackground> {
  ScrollNotificationObserverState? _observer;
  bool _scrolledUnder = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_handle);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_handle);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handle);
    super.dispose();
  }

  void _handle(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification || !defaultScrollNotificationPredicate(notification)) return;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return;
    final scrolled = metrics.extentBefore > 0;
    if (scrolled != _scrolledUnder) setState(() => _scrolledUnder = scrolled);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _scrolledUnder ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      child: const GlassContainer(
        borderRadius: BorderRadius.zero,
        showEdgeHighlight: false,
        child: SizedBox.expand(),
      ),
    );
  }
}
