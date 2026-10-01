import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Live Activity "Právě hraje" (iOS 16.2+): zamčená obrazovka a Dynamic
/// Island s obalem ve "fun shape" výřezu (vzhled: ios/OpentifyWidgets).
/// Na jiných platformách nic nedělá.
class NowPlayingActivity {
  NowPlayingActivity._();

  static const _channel = MethodChannel('opentify/live_activity');
  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static String? _artKey;
  static Uint8List? _art;

  /// Ve výchozím stavu VYPNUTO: na zámku je už systémový přehrávač s obalem
  /// a karta pod ním byla zbytečně podruhé (živě nahlášeno). Profil › Vzhled.
  static const _prefKey = 'appearance.live_activity';
  static bool enabled = false;

  static Future<void> loadSetting() async {
    try {
      enabled = (await SharedPreferences.getInstance()).getBool(_prefKey) ?? false;
    } catch (_) {}
    // Vypnuto -> případnou kartu z předchozího spuštění sklidit.
    if (!enabled) unawaited(end());
  }

  static Future<void> setEnabled(bool value) async {
    enabled = value;
    _artKey = null; // při zapnutí poslat obal znovu
    if (!value) await end();
    try {
      await (await SharedPreferences.getInstance()).setBool(_prefKey, value);
    } catch (_) {}
  }

  /// Stav skladby. `artworkUrl` se stáhne a zmenší jen při změně.
  static Future<void> update({
    required String recordingId,
    required String title,
    required String artist,
    required String? artworkUrl,
    required Color color,
    required bool playing,
  }) async {
    if (!_supported || !enabled) return;
    try {
      if (artworkUrl != _artKey) {
        _artKey = artworkUrl;
        _art = artworkUrl == null ? null : await _thumbnail(artworkUrl);
      }
      await _channel.invokeMethod('update', {
        'title': title,
        'artist': artist,
        if (_art != null) 'art': _art,
        if (_art != null) 'artKey': recordingId,
        'shape': recordingId.hashCode.abs() % 6,
        'color': '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        'playing': playing,
      });
    } catch (e) {
      debugPrint('NowPlayingActivity.update: $e');
    }
  }

  static Future<void> end() async {
    if (!_supported) return;
    _artKey = null;
    _art = null;
    try {
      await _channel.invokeMethod('end');
    } catch (_) {}
  }

  /// Obal zmenšený na 256 px (PNG) -- do sdíleného kontejneru appky
  /// a rozšíření, Live Activity sama nic stahovat nesmí.
  static Future<Uint8List?> _thumbnail(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final codec = await ui.instantiateImageCodec(response.bodyBytes, targetWidth: 256, targetHeight: 256);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }
}
