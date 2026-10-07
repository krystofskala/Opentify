import 'dart:ui' show Offset, Rect;

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:share_plus/share_plus.dart';

/// Střed obrazovky jako místo, odkud se nabídka sdílení otevírá (iOS ho
/// vyžaduje, viz níž). Používá i sdílení obrázků (share_image_io.dart).
Rect? shareOrigin() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return null;
  final view = views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.width <= 0 || size.height <= 0) return null;
  return Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
}

/// Nativní appka: systémové sdílení (iOS share sheet).
///
/// iOS (26) chce místo, odkud se nabídka otevírá (`sharePositionOrigin`) --
/// s prázdným obdélníkem spadla ("must be non-zero", živě 7. 10.: "Poslat
/// odkaz" nedělalo nic). Střed obrazovky stačí. Selže-li sdílení i tak,
/// `false` -> volající odkaz zkopíruje do schránky.
Future<bool> nativeShare(String text, String url) async {
  try {
    await Share.share('$text\n$url', sharePositionOrigin: shareOrigin());
    return true;
  } catch (_) {
    return false;
  }
}
