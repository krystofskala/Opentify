import 'package:flutter/foundation.dart' show TargetPlatform, ValueNotifier, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_nav.dart';

/// Klíč zařízení v NATIVNÍ appce. Web ho má v cookie (posílá ji prohlížeč
/// sám); nativní HTTP cookies neukládá, takže si klíč z `/auth/me` nebo
/// `/auth/join` uložíme a posíláme jako `Authorization: Bearer` -- u streamu,
/// obrázků a WebSocketu (tam hlavička nejde) jako `?t=` (backend
/// `token_from_request` bere obojí).
String? deviceToken;

/// Admin jedná za jiný profil -- JEDINÝ zdroj pravdy na webu i v appce:
/// posílá se v každém požadavku (`X-Act-As`, u WebSocketu `act_as`). Dřív
/// web spoléhal na cookie na 10 let, kterou prohlížeč posílal sám -- appka
/// si myslela jedno, server druhé (živě: "moje nastavení, tátova Domů").
String? actAsProfile;

const _tokenKey = 'auth.device_token';
const _actAsKey = 'auth.act_as';
const _actAsAtKey = 'auth.act_as_at';

/// Přepnutí na jiný profil po téhle době samo vyprší (zapomenuté přepnutí
/// by jinak po restartu tiše pokračovalo).
const actAsLifetime = Duration(hours: 3);

/// Klíč zařízení v systémovém trezoru (iOS Keychain, Android Keystore), ne
/// v běžném úložišti appky -- to Android kopíroval do zálohy na Google Disk.
/// iOS: dostupný i po prvním odemčení (`first_unlock`), ne jen při odemčeném
/// telefonu -- appka spuštěná na pozadí na zamčeném iPhonu (výchozí
/// `unlocked`) klíč nepřečetla a běžela odhlášená.
const _secure = FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock));

/// Starší položka uložená s výchozím `unlocked` -- dotaz s jinou dostupností
/// ji nenajde (plugin dostupnost dává do dotazu), proto číst i takhle.
const _secureLegacy = FlutterSecureStorage();

/// Zvýší se, když se klíč podařilo přečíst až dodatečně (po návratu do
/// appky) -- `authProvider` se pak načte znovu a WS se připojí s klíčem.
final ValueNotifier<int> deviceTokenRecovered = ValueNotifier<int>(0);

AppLifecycleListener? _retryOnResume;

/// Přečte klíč z trezoru; starou iOS položku (`unlocked`) přestěhuje na
/// `first_unlock`. Výjimka = trezor teď nejde (zamčený telefon).
Future<String?> _readSecure() async {
  final token = await _secure.read(key: _tokenKey);
  if (token != null || defaultTargetPlatform != TargetPlatform.iOS) return token;
  final old = await _secureLegacy.read(key: _tokenKey);
  if (old != null) {
    // `delete` maže bez ohledu na dostupnost; zápis s novou by jinak narazil
    // na duplicitní položku.
    try {
      await _secure.delete(key: _tokenKey);
      await _secure.write(key: _tokenKey, value: old);
    } catch (_) {
      // Přestěhování nevyšlo -- vrátit starou položku, ať se klíč neztratí.
      try {
        await _secureLegacy.write(key: _tokenKey, value: old);
      } catch (_) {}
    }
  }
  return old;
}

/// Trezor při startu nešel přečíst: nebrat to jako odhlášení natrvalo --
/// zkusit znovu při návratu do appky (telefon už je odemčený).
void _scheduleRetry() {
  _retryOnResume ??= AppLifecycleListener(onResume: () async {
    try {
      final token = await _readSecure();
      _retryOnResume?.dispose();
      _retryOnResume = null;
      if (token == null || token == deviceToken) return;
      deviceToken = token;
      await NativeNav.syncConfig();
      deviceTokenRecovered.value++;
    } catch (_) {
      // Pořád zamčeno -- příště.
    }
  });
}

Future<void> _loadActAs() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_actAsKey);
    final at = DateTime.tryParse(prefs.getString(_actAsAtKey) ?? '');
    if (id != null && (at == null || DateTime.now().difference(at) > actAsLifetime)) {
      await prefs.remove(_actAsKey);
      await prefs.remove(_actAsAtKey);
      actAsProfile = null;
    } else {
      actAsProfile = id;
    }
  } catch (_) {}
}

Future<void> loadDeviceToken() async {
  await _loadActAs();
  if (kIsWeb) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_tokenKey);
    try {
      deviceToken = await _readSecure();
      // Starší verze měla klíč v běžném úložišti -- přestěhovat a smazat.
      if (deviceToken == null && legacy != null) {
        await _secure.write(key: _tokenKey, value: legacy);
        deviceToken = legacy;
      }
      if (legacy != null) await prefs.remove(_tokenKey);
    } catch (_) {
      // Trezor teď nejde (zamčený telefon, obnova zálohy): klíč ze starého
      // úložiště, pokud tam je, a znovu zkusit po návratu do appky.
      deviceToken = legacy;
      _scheduleRetry();
    }
  } catch (_) {}
  await NativeNav.syncConfig();
}

Future<void> saveDeviceToken(String token) async {
  if (kIsWeb) return;
  deviceToken = token;
  // Nový klíč z přihlášení -- dodatečné čtení starého už nemá co přepsat.
  _retryOnResume?.dispose();
  _retryOnResume = null;
  try {
    try {
      await _secure.write(key: _tokenKey, value: token);
    } catch (_) {
      // Stará položka s jinou dostupností (iOS) -- smazat a zapsat znovu.
      await _secure.delete(key: _tokenKey);
      await _secure.write(key: _tokenKey, value: token);
    }
  } catch (_) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
    } catch (_) {}
  }
  await NativeNav.syncConfig();
}

/// Odhlášení: zapomenout klíč zařízení (a přepnutí na jiný profil).
Future<void> clearDeviceToken() async {
  deviceToken = null;
  actAsProfile = null;
  _retryOnResume?.dispose();
  _retryOnResume = null;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_actAsKey);
    await prefs.remove(_actAsAtKey);
  } catch (_) {}
  if (kIsWeb) return;
  try {
    await _secure.delete(key: _tokenKey);
  } catch (_) {}
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_actAsKey);
  } catch (_) {}
  await NativeNav.syncConfig();
}

Future<void> saveActAs(String? userId) async {
  actAsProfile = userId;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (userId == null) {
      await prefs.remove(_actAsKey);
      await prefs.remove(_actAsAtKey);
    } else {
      await prefs.setString(_actAsKey, userId);
      await prefs.setString(_actAsAtKey, DateTime.now().toIso8601String());
    }
  } catch (_) {}
  if (!kIsWeb) await NativeNav.syncConfig();
}

/// Hlavičky přihlášení pro nativní appku (web: prázdné).
Map<String, String> authHeaders() => {
      if (deviceToken != null) 'Authorization': 'Bearer $deviceToken',
      if (actAsProfile != null) 'X-Act-As': actAsProfile!,
    };

/// URL na vlastní backend s klíčem v dotazu (stream, obrázek, WebSocket).
/// Adresa bez tokenu zařízení (`t=`) -- než odejde jinam (Connect: ostatní
/// zařízení si přidají svůj, `withDeviceToken`).
String withoutDeviceToken(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.queryParameters.containsKey('t')) return url;
  final rest = {...uri.queryParameters}..remove('t');
  // `replace(queryParameters: null)` dotaz NEodstraní (audit 8. 10.) -- bez
  // zbylých parametrů adresa bez "?".
  if (rest.isEmpty) return url.split('?').first;
  return uri.replace(queryParameters: rest).toString();
}

String withDeviceToken(String url) {
  final token = deviceToken;
  if (kIsWeb || token == null) return url;
  final uri = Uri.parse(url);
  return uri.replace(queryParameters: {...uri.queryParameters, 't': token}).toString();
}
