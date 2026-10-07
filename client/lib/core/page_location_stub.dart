import 'dart:ui' show PlatformDispatcher;

import 'config.dart';
import 'join_route.dart';
import 'app_restart.dart';

/// Pozvánka z odkazu, kterým se appka spustila (`opentify:///join/KÓD` přes
/// `o.html`, Flutter deep linking): `defaultRouteName` nese cestu odkazu.
bool _joinUsed = false;

String? joinCodeFromUrl() {
  if (_joinUsed) return null;
  return joinCodeFromRoute(PlatformDispatcher.instance.defaultRouteName);
}

void clearJoinFromUrl() => _joinUsed = true;
void rememberLaunchJoinCode() {} // nativně je odkaz v `defaultRouteName` napořád
void reloadPage() => restartApp();
String appOrigin() {
  const origin = String.fromEnvironment('APP_ORIGIN');
  return origin.isNotEmpty ? origin : AppConfig.sharedOrigin;
}
