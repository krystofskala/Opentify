import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'device_token.dart';
import '../features/share/share_card_screen.dart' show openShareCard;

/// Most k nativní části iOS (kanál `opentify/nav`):
///  - tlačítka v Ovládacím centru (Ladička) a klepnutí na upozornění Shazamu
///    nechají v nativní části cestu (`/tuner`, `/library/shazam`), appka ji
///    tady vyzvedne -- hned, nebo po návratu do popředí. Vlastní adresa
///    `opentify://` přes OpenURLIntent z ovládacího prvku nedělala nic.
///  - nativní Shazam na pozadí potřebuje adresu serveru a klíč zařízení,
///    `syncConfig` mu je předá (App Group).
class NativeNav {
  NativeNav._();

  static const _channel = MethodChannel('opentify/nav');
  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static AppLifecycleListener? _lifecycle;

  static void attach(GoRouter router) {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) _open(router, call.arguments as String);
      if (call.method == 'screenshot') _offerShareCard(router);
    });
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(_pull(router)));
    unawaited(_pull(router));
  }

  static Future<void> _pull(GoRouter router) async {
    try {
      final route = await _channel.invokeMethod<String>('pending');
      if (route != null) _open(router, route);
      // Deník nativní části (Shazam na pozadí apod.) -- co nestihlo odejít.
      final log = await _channel.invokeListMethod<String>('takeLog');
      if (log != null && log.isNotEmpty) diagReport('native-log', log.join('\n'));
    } catch (e) {
      debugPrint('NativeNav.pending: $e');
    }
  }

  /// Screenshot v přehrávači: nabídnout kartu ke sdílení (jako Spotify).
  static void _offerShareCard(GoRouter router) {
    if (router.routerDelegate.currentConfiguration.uri.path != '/now-playing') return;
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(persist: false, 
      content: const Text('Sdílet jako obrázek?'),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(label: 'Sdílet', onPressed: () => openShareCard(context)),
    ));
  }

  static void _open(GoRouter router, String route) {
    // Po studeném startu ještě nemusí být navigátor -- o snímek později.
    WidgetsBinding.instance.addPostFrameCallback((_) => router.push(route));
  }

  static Future<void> syncConfig() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('config', {
        'apiBase': AppConfig.apiBaseUrl,
        'token': deviceToken,
        'actAs': actAsProfile,
      });
    } catch (e) {
      debugPrint('NativeNav.config: $e');
    }
  }
}
