import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

// Web Share API přímo přes js_interop (nainstalovaná verze package:web ho
// nemá).
@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external JSPromise<JSAny?> share(_ShareData data);
}

extension type _ShareData._(JSObject _) implements JSObject {
  external factory _ShareData({String title, String text, String url});
}

/// Web Share API jen na dotykových zařízeních (telefon/tablet) -- na PC je
/// užitečnější rovnou zkopírovat odkaz. `false` = nesdíleno, volající odkaz
/// zkopíruje. Musí se zavolat synchronně v obsluze klepnutí (Safari).
Future<bool> nativeShare(String text, String url) async {
  try {
    final coarse = web.window.matchMedia('(pointer: coarse)').matches;
    if (!coarse || !_navigator.has('share')) return false;
    await _navigator.share(_ShareData(title: text.split('\n').first, text: text, url: url)).toDart;
    return true;
  } catch (e) {
    // Uživatel sdílení zrušil (AbortError) -- to je taky "vyřízeno", ne
    // důvod kopírovat; jinak spadne na kopírování.
    return e.toString().contains('AbortError');
  }
}
