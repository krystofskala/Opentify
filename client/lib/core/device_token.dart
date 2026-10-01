import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'native_nav.dart';

/// Klíč zařízení v NATIVNÍ appce. Web ho má v cookie (posílá ji prohlížeč
/// sám); nativní HTTP cookies neukládá, takže si klíč z `/auth/me` nebo
/// `/auth/join` uložíme a posíláme jako `Authorization: Bearer` -- u streamu,
/// obrázků a WebSocketu (tam hlavička nejde) jako `?t=` (backend
/// `token_from_request` bere obojí).
String? deviceToken;

/// Admin jedná za jiný profil (web: cookie `opentify_act_as`).
String? actAsProfile;

const _tokenKey = 'auth.device_token';
const _actAsKey = 'auth.act_as';

Future<void> loadDeviceToken() async {
  if (kIsWeb) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    deviceToken = prefs.getString(_tokenKey);
    actAsProfile = prefs.getString(_actAsKey);
  } catch (_) {}
  await NativeNav.syncConfig();
}

Future<void> saveDeviceToken(String token) async {
  if (kIsWeb) return;
  deviceToken = token;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  } catch (_) {}
  await NativeNav.syncConfig();
}

/// Odhlášení: zapomenout klíč zařízení (a přepnutí na jiný profil).
Future<void> clearDeviceToken() async {
  deviceToken = null;
  actAsProfile = null;
  if (kIsWeb) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_actAsKey);
  } catch (_) {}
  await NativeNav.syncConfig();
}

Future<void> saveActAs(String? userId) async {
  if (kIsWeb) return;
  actAsProfile = userId;
  try {
    final prefs = await SharedPreferences.getInstance();
    userId == null ? await prefs.remove(_actAsKey) : await prefs.setString(_actAsKey, userId);
  } catch (_) {}
  await NativeNav.syncConfig();
}

/// Hlavičky přihlášení pro nativní appku (web: prázdné).
Map<String, String> authHeaders() => {
      if (deviceToken != null) 'Authorization': 'Bearer $deviceToken',
      if (actAsProfile != null) 'X-Act-As': actAsProfile!,
    };

/// URL na vlastní backend s klíčem v dotazu (stream, obrázek, WebSocket).
String withDeviceToken(String url) {
  final token = deviceToken;
  if (kIsWeb || token == null) return url;
  final uri = Uri.parse(url);
  return uri.replace(queryParameters: {...uri.queryParameters, 't': token}).toString();
}
