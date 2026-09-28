import 'package:figma_squircle/figma_squircle.dart';

import 'design_tokens.dart';

/// "Squircle" (kontinuální zaoblení rohů, ne kruhový oblouk) -- PixelPlayerův
/// `AbsoluteSmoothCornerShape` ekvivalent přes `figma_squircle`. Tohle je
/// jeden z hlavních vizuálních signálů "vypadá jako PixelPlay, ne jako
/// obecná Material appka" -- plain `RoundedRectangleBorder` má ostrý přechod
/// mezi rovnou hranou a obloukem, squircle je plynulý po celé délce.
class AppShapes {
  const AppShapes._();

  static const double smoothing = 0.6;

  static SmoothRectangleBorder of(double radius, {double smoothing = AppShapes.smoothing}) {
    return SmoothRectangleBorder(
      borderRadius: SmoothBorderRadius(cornerRadius: radius, cornerSmoothing: smoothing),
    );
  }

  static final SmoothRectangleBorder xs = of(AppRadii.xs);
  static final SmoothRectangleBorder sm = of(AppRadii.sm);
  static final SmoothRectangleBorder md = of(AppRadii.md);
  static final SmoothRectangleBorder lg = of(AppRadii.lg);
  static final SmoothRectangleBorder xl = of(AppRadii.xl);

  /// Plně kulatý/kapslový tvar -- `cornerRadius` větší než polovina kratší
  /// strany se stejně jako u `BorderRadius.circular` vyklipuje na maximum.
  static final SmoothRectangleBorder pill = of(AppRadii.pill);
}
