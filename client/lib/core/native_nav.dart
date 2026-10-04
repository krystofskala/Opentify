import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'device_token.dart';
import '../features/share/share_card_screen.dart' show openShareCard;
import '../widgets/now_playing_sheet.dart' show NowPlayingSheetController;
import '../widgets/toast.dart';

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

  /// Aktuální router -- po restartu appky (přepnutí profilu) je jiný, a
  /// posluchač vzniká jen jednou (dřív navigoval do prvního, mrtvého).
  static GoRouter? _router;

  static void attach(GoRouter router) {
    if (!_supported) return;
    _router = router;
    _channel.setMethodCallHandler((call) async {
      final current = _router;
      if (current == null) return;
      if (call.method == 'open' && call.arguments is String) _open(current, call.arguments as String);
      if (call.method == 'screenshot') _offerShareCard(current);
    });
    _lifecycle ??= AppLifecycleListener(onResume: () {
      final current = _router;
      if (current != null) unawaited(_pull(current));
    });
    unawaited(_pull(router));
  }

  /// Router se ruší (restart appky) -- už ho nepoužívat.
  static void detach(GoRouter router) {
    if (identical(_router, router)) _router = null;
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
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context == null) return;
    // `push` mění jen poslední shodu, ne `uri` konfigurace (ta hlásí záložku)
    // -- otevřený přehrávač ví sheet.
    if (!(NowPlayingSheetController.maybeOf(context)?.isOpen ?? false)) return;
    toast(context, 'Sdílet jako obrázek?',
        action: SnackBarAction(label: 'Sdílet', onPressed: () => openShareCard(context)));
  }

  static void _open(GoRouter router, String route) {
    // Po studeném startu ještě nemusí být navigátor -- o snímek později.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_router, router)) router.push(route);
    });
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
