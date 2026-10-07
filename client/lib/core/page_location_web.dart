import 'config.dart';
import 'join_route.dart';
import 'package:web/web.dart' as web;

/// Kód zachycený při startu (`rememberLaunchJoinCode` v `main`) -- router
/// pak `#/join/KÓD` přesměruje na `#/` dřív, než se přihlášení na adresu
/// podívá, a pozvánka přes o.html končila na obyčejném přihlášení.
String? _launchCode;
bool _used = false;

void rememberLaunchJoinCode() {
  _launchCode = _readJoinCode();
}

String? joinCodeFromUrl() {
  if (_used) return null;
  return _readJoinCode() ?? _launchCode;
}

String? _readJoinCode() {
  try {
    final uri = Uri.parse(web.window.location.href);
    final code = uri.queryParameters['join'];
    if (code != null && code.isNotEmpty) return code;
    // Odkaz z pozvánky přes o.html: `#/join/KÓD`.
    return uri.fragment.isEmpty ? null : joinCodeFromRoute(uri.fragment);
  } catch (_) {
    return null;
  }
}

void clearJoinFromUrl() {
  _used = true;
  try {
    final uri = Uri.parse(web.window.location.href);
    final params = Map<String, String>.from(uri.queryParameters)..remove('join');
    final clean = uri.replace(queryParameters: params.isEmpty ? null : params).toString();
    web.window.history.replaceState(null, '', clean.endsWith('?') ? clean.substring(0, clean.length - 1) : clean);
  } catch (_) {}
}

void reloadPage() {
  try {
    web.window.location.reload();
  } catch (_) {}
}

String appOrigin() {
  try {
    return web.window.location.origin;
  } catch (_) {
    return AppConfig.sharedOrigin;
  }
}
