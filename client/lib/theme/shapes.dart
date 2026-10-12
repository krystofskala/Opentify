import 'package:flutter/painting.dart';

import 'design_tokens.dart';

/// "Squircle" (kontinuální zaoblení rohů, ne kruhový oblouk) přes vestavěný
/// `RoundedSuperellipseBorder` Flutteru -- plain `RoundedRectangleBorder` má
/// ostrý přechod mezi rovnou hranou a obloukem, superelipsa je plynulá po
/// celé délce (stejný princip jako „continuous corners“ v iOS).
class AppShapes {
  const AppShapes._();

  static RoundedSuperellipseBorder of(double radius) {
    return RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));
  }

  static final RoundedSuperellipseBorder xs = of(AppRadii.xs);
  static final RoundedSuperellipseBorder sm = of(AppRadii.sm);
  static final RoundedSuperellipseBorder md = of(AppRadii.md);
  static final RoundedSuperellipseBorder lg = of(AppRadii.lg);
  static final RoundedSuperellipseBorder xl = of(AppRadii.xl);

  /// Plně kulatý/kapslový tvar -- poloměr větší než polovina kratší strany
  /// se stejně jako u `BorderRadius.circular` omezí na maximum.
  static final RoundedSuperellipseBorder pill = of(AppRadii.pill);
}
