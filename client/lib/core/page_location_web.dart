import 'package:web/web.dart' as web;

String? joinCodeFromUrl() {
  try {
    final code = Uri.parse(web.window.location.href).queryParameters['join'];
    return code == null || code.isEmpty ? null : code;
  } catch (_) {
    return null;
  }
}

void clearJoinFromUrl() {
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
    return 'https://desktop-2lissjt.tail343940.ts.net';
  }
}
