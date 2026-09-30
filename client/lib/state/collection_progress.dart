import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import 'providers.dart';

/// Kde uživatel v albu/playlistu skončil -- u dlouhých playlistů (100
/// skladeb) si to nemusí pamatovat, detail nabídne "Pokračovat".
/// Sdílí se přes server mezi zařízeními: `deviceId` = kdo zapsal naposled,
/// `updatedAt` = čas serveru (ne hodiny zařízení -- ty se můžou lišit).
typedef CollectionProgress = ({
  String recordingId,
  String title,
  int index,
  int total,
  int positionMs,
  String? deviceId,
  DateTime? updatedAt,
});

/// Klíč = stránka alba/playlistu ("/releases/<id>", "/playlists/<id>").
class CollectionProgressController extends StateNotifier<Map<String, CollectionProgress>> {
  CollectionProgressController(this._ref) : super(const {}) {
    _load();
  }

  final Ref _ref;

  static const _prefKey = 'player.collection_progress';
  static const _maxEntries = 60;

  static bool isCollection(String? route) =>
      route != null && (route.startsWith('/releases/') || route.startsWith('/playlists/'));

  ApiClient get _api => _ref.read(apiClientProvider);
  String get deviceId => _api.deviceId;

  // Poslední odeslání na server (pozice se posílá nejvýš jednou za 10 s,
  // změna skladby hned).
  final Map<String, DateTime> _sentAt = {};
  final Map<String, String> _sentTrack = {};

  static CollectionProgress _fromJson(Map<String, dynamic> j) => (
        recordingId: j['recordingId'] as String? ?? j['id'] as String,
        title: j['title'] as String? ?? j['t'] as String? ?? '',
        index: (j['index'] ?? j['i']) as int? ?? 0,
        total: (j['total'] ?? j['n']) as int? ?? 0,
        positionMs: (j['positionMs'] ?? j['p']) as int? ?? 0,
        deviceId: j['deviceId'] as String?,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      );

  static Map<String, dynamic> _toJson(CollectionProgress p) => {
        'recordingId': p.recordingId,
        'title': p.title,
        'index': p.index,
        'total': p.total,
        'positionMs': p.positionMs,
        'deviceId': p.deviceId,
        'updatedAt': p.updatedAt?.toIso8601String(),
      };

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && mounted) {
        final map = (jsonDecode(raw) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, _fromJson(v as Map<String, dynamic>)));
        state = {...map, ...state};
      }
    } catch (_) {}
    await refresh();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode({for (final e in state.entries) e.key: _toJson(e.value)}));
    } catch (_) {}
  }

  /// Stav ze serveru (start appky, návrat do ní). Novější zápis z jiného
  /// zařízení přepíše místní.
  Future<void> refresh() async {
    try {
      final json = await _api.getJson('/library/progress');
      final remote = (json['items'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, _fromJson(v as Map<String, dynamic>)));
      if (!mounted) return;
      final next = {...state};
      remote.forEach((route, p) {
        final local = next[route];
        final newer = local?.updatedAt == null ||
            (p.updatedAt != null && p.updatedAt!.isAfter(local!.updatedAt!));
        if (local == null || newer) next[route] = p;
      });
      state = next;
      _save();
    } catch (_) {
      // Offline -- zůstává místní stav.
    }
  }

  /// Poslední stav od JINÉHO zařízení, novější než to, co jsme sem zapsali
  /// my -- pak má tohle zařízení navázat, ne pokračovat ze staré pozice.
  CollectionProgress? newerFromOtherDevice(String route) {
    final p = state[route];
    if (p == null || p.deviceId == null || p.deviceId == deviceId) return null;
    return p;
  }

  void record(String route, CollectionProgress progress) {
    final current = state[route];
    if (current != null &&
        current.recordingId == progress.recordingId &&
        current.positionMs == progress.positionMs &&
        current.deviceId == deviceId) {
      return;
    }
    // Naposledy poslouchané na konec (nejstarší se zahazují).
    final next = {...state}..remove(route);
    next[route] = (
      recordingId: progress.recordingId,
      title: progress.title,
      index: progress.index,
      total: progress.total,
      positionMs: progress.positionMs,
      deviceId: deviceId,
      updatedAt: current?.updatedAt,
    );
    while (next.length > _maxEntries) {
      next.remove(next.keys.first);
    }
    state = next;
    _save();

    final now = DateTime.now();
    final trackChanged = _sentTrack[route] != progress.recordingId;
    final last = _sentAt[route];
    if (!trackChanged && last != null && now.difference(last) < const Duration(seconds: 10)) return;
    _sentAt[route] = now;
    _sentTrack[route] = progress.recordingId;
    unawaited(_push(route, progress));
  }

  Future<void> _push(String route, CollectionProgress p) async {
    try {
      final json = await _api.putJson('/library/progress', body: {
        'route': route,
        'recordingId': p.recordingId,
        'title': p.title,
        'index': p.index,
        'total': p.total,
        'positionMs': p.positionMs,
      });
      final saved = _fromJson(json);
      if (!mounted) return;
      final local = state[route];
      if (local != null && local.recordingId == saved.recordingId) {
        state = {...state, route: (
          recordingId: local.recordingId,
          title: local.title,
          index: local.index,
          total: local.total,
          positionMs: local.positionMs,
          deviceId: deviceId,
          updatedAt: saved.updatedAt,
        )};
        _save();
      }
    } catch (_) {}
  }

  void clear(String route) {
    if (!state.containsKey(route)) return;
    state = {...state}..remove(route);
    _save();
    unawaited(_api.deleteJson('/library/progress?route=${Uri.encodeQueryComponent(route)}').then<void>(
          (_) {},
          onError: (Object _) {},
        ));
  }
}

final collectionProgressProvider =
    StateNotifierProvider<CollectionProgressController, Map<String, CollectionProgress>>(
        (ref) => CollectionProgressController(ref));
