import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'config.dart';
import 'device_token.dart';

/// Nativní "černá skříňka": posledních 30 kroků v paměti, hlášení jde na
/// server do logu API (`POST /client-log`) -- stejně jako z webu
/// (web/index.html). Bez toho nejsou chyby z iPhonu vidět vůbec.
final List<String> _notes = [];
var _sent = 0;

void diagNote(String text) {
  _notes.add('${DateTime.now().toIso8601String().substring(11, 19)} $text');
  if (_notes.length > 30) _notes.removeAt(0);
}

void diagReport(String kind, String detail) {
  if (_sent++ > 50) return; // ať chybová smyčka nezahltí log
  final body = jsonEncode({
    'kind': kind,
    'detail': detail.length > 4000 ? detail.substring(0, 4000) : detail,
    'platform': Platform.operatingSystem,
    'notes': _notes,
  });
  http
      .post(Uri.parse('${AppConfig.apiBaseUrl}/client-log'),
          headers: {'Content-Type': 'application/json', ...authHeaders()}, body: body)
      .timeout(const Duration(seconds: 10))
      .then((_) {}, onError: (Object _) {});
}
