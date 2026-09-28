import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

web.HTMLElement? _probe;

/// Neviditelný prvek s `padding: env(safe-area-inset-*)` -- prohlížeč ho
/// spočítá v CSS pixelech, což jsou přesně Flutterí logické pixely.
EdgeInsets readSafeAreaInsets() {
  try {
    var probe = _probe;
    if (probe == null) {
      probe = web.document.createElement('div') as web.HTMLElement;
      probe.style.cssText = 'position:fixed;top:0;left:0;width:0;height:0;visibility:hidden;pointer-events:none;'
          'padding-top:env(safe-area-inset-top,0px);padding-right:env(safe-area-inset-right,0px);'
          'padding-bottom:env(safe-area-inset-bottom,0px);padding-left:env(safe-area-inset-left,0px);';
      web.document.body?.append(probe);
      _probe = probe;
    }
    final style = web.window.getComputedStyle(probe);
    double px(String value) => double.tryParse(value.replaceAll('px', '')) ?? 0;
    return EdgeInsets.fromLTRB(
      px(style.paddingLeft),
      px(style.paddingTop),
      px(style.paddingRight),
      px(style.paddingBottom),
    );
  } catch (_) {
    return EdgeInsets.zero;
  }
}
