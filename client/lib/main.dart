import 'core/app_restart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/desktop_audio.dart';
import 'core/device_token.dart';
import 'core/media_session.dart';
import 'core/now_playing_activity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/diagnostics.dart';
import 'core/safe_area_insets.dart';

/// Vstupní bod. Primárně cílíme na `flutter run -d chrome` pro rychlé
/// testování proti lokálnímu backendu (viz README.md v tomhle adresáři pro
/// `--dart-define` proměnné base URL) -- `ProviderScope` je jediné, co main
/// potřebuje, veškerá závislost na backendu žije v `state/providers.dart`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Nativní appka: uložený klíč zařízení dřív, než odejde první požadavek.
  await loadDeviceToken();
  await NowPlayingActivity.loadSetting();
  // Windows: just_audio přes media_kit (libmpv).
  initDesktopAudio();
  // Nativní appka: ovládání na zamčené obrazovce (audio_service).
  try {
    await initMediaSession();
  } catch (e) {
    debugPrint('initMediaSession: $e');
  }
  // Chyby Dartu do "černé skříňky" (diagnostika zamrzání, viz index.html).
  var reports = 0;
  String short(Object error, StackTrace? stack) =>
      '$error\n${(stack?.toString() ?? '').split('\n').take(14).join('\n')}';
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    diagNote('flutter error: ${details.exceptionAsString()}');
    if (reports++ < 20) diagReport('flutter-error', short(details.exception, details.stack));
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    diagNote('dart error: $error');
    if (reports++ < 20) diagReport('dart-error', short(error, stack));
    return false;
  };
  // Klíč podle `appRestartTick` -- přepnutí profilu / odhlášení v nativní
  // appce zahodí celý stav a začne znovu (web znovu načte stránku).
  runApp(ValueListenableBuilder<int>(
    valueListenable: appRestartTick,
    builder: (context, tick, _) =>
        ProviderScope(key: ValueKey(tick), child: const WebSafeAreaInsets(child: OpentifyApp())),
  ));
}
