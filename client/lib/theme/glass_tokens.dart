import 'dart:ui';

/// Ladicí hodnoty "Liquid Glass" efektu (`GlassContainer`) -- `saturation`
/// je zámerně nastavená vysoko (+40 %), protože právě tohle byl chybějící
/// kus mezi naším původním plochým blur+gradient efektem a skutečným Apple
/// Liquid Glass/PixelPlay vzhledem (viz github.com/rdev/liquid-glass-react,
/// jehož React komponenta má `saturation` výchozí na 140 %). Mimo scope
/// zůstává myší tažená `feDisplacementMap` refrakce téže knihovny -- ta by
/// vyžadovala vlastní `dart:ui` `FragmentShader`, ne jen `BackdropFilter`.
class GlassTokens {
  const GlassTokens._();

  static const double blurLight = 16;
  static const double blurMedium = 24;
  static const double blurHeavy = 40;

  static const double saturation = 1.4;
  static const double edgeHighlightAlpha = 0.35;
  static const double borderAlpha = 0.14;
}

/// Luminance-preserving saturační matice (stejný vzorec jako Androidí
/// `ColorMatrix.setSaturation`/CSS `filter: saturate()`) -- `amount == 1`
/// je identita, `> 1` sytost zvyšuje. Použitelné přímo jako `ImageFilter`
/// (přes `ColorFilter`), takže se dá složit s blurem do jednoho
/// `BackdropFilter.filter` bez extra widgetové vrstvy.
ColorFilter saturationColorFilter(double amount) {
  const lumR = 0.213, lumG = 0.715, lumB = 0.072;
  final inv = 1 - amount;
  final ir = inv * lumR, ig = inv * lumG, ib = inv * lumB;
  return ColorFilter.matrix(<double>[
    ir + amount, ig, ib, 0, 0,
    ir, ig + amount, ib, 0, 0,
    ir, ig, ib + amount, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}
