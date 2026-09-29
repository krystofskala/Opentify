import 'package:web/web.dart' as web;

bool shouldUseRadioStream() {
  try {
    final href = web.window.location.href;
    if (href.contains('radio=1')) return true;
    if (href.contains('radio=0')) return false;
    final ua = web.window.navigator.userAgent;
    if (ua.contains('iPhone') || ua.contains('iPad') || ua.contains('iPod')) return true;
    // iPadOS se hlásí jako Mac -- pozná se podle dotykové obrazovky.
    return ua.contains('Macintosh') && web.window.navigator.maxTouchPoints > 1;
  } catch (_) {
    return false;
  }
}
