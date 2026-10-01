import 'package:flutter/foundation.dart' show kIsWeb;

/// Konfigurace prostředí, přepsatelná přes `--dart-define` při buildu/spuštění,
/// např.:
///
/// ```
/// flutter run -d chrome \
///   --dart-define=API_BASE_URL=http://localhost:8000/api/v1 \
///   --dart-define=WS_BASE_URL=ws://localhost:8000/ws
/// ```
class AppConfig {
  const AppConfig._();

  static const _apiBaseDefine = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000/api/v1',
  );

  static const _wsBaseDefine = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://localhost:8000/ws',
  );

  /// Web otevřený přes Tailscale mluví se serverem, ze kterého se načetl --
  /// stejný build pak funguje na `desktop-…ts.net` (moje zařízení) i na
  /// samostatném `opentify.…ts.net` (sdílený jen tenhle stroj, ne celé PC).
  static String get apiBaseUrl => _sameOrigin(_apiBaseDefine, 'https');
  static String get wsBaseUrl => _sameOrigin(_wsBaseDefine, 'wss');

  static String _sameOrigin(String url, String scheme) {
    if (!kIsWeb) return url;
    final page = Uri.base;
    if (!page.host.endsWith('.ts.net')) return url;
    return Uri.parse(url).replace(scheme: scheme, host: page.host).toString();
  }

  /// Backend (app/auth.py) má zatím jen zjednodušenou auth přes hlavičky
  /// `X-User-Id`/`X-Device-Id` — TODO tamtéž počítá s náhradou za device
  /// JWT. Klient se tomu drží 1:1, dokud auth vrstva nedoběhne.
  static const userId = String.fromEnvironment('VAULT_USER_ID', defaultValue: 'demo-user');

  /// Web build v Chrome nemá stabilní zařízení identitu jako mobil/desktop
  /// — vygenerujeme ji jednou při startu procesu, aby šlo v devu otestovat
  /// multi-device sync mezi dvěma taby/okny s různým `VAULT_DEVICE_ID`.
  static final String deviceId = _resolveDeviceId();

  static String _resolveDeviceId() {
    const fromEnv = String.fromEnvironment('VAULT_DEVICE_ID', defaultValue: '');
    if (fromEnv.isNotEmpty) return fromEnv;
    return 'flutter-${DateTime.now().microsecondsSinceEpoch}';
  }
}
