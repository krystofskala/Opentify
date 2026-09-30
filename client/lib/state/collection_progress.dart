import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kde uživatel v albu/playlistu skončil -- u dlouhých playlistů (100
/// skladeb) si to nemusí pamatovat, detail nabídne "Pokračovat".
typedef CollectionProgress = ({String recordingId, String title, int index, int total, int positionMs});

/// Klíč = stránka alba/playlistu ("/releases/<id>", "/playlists/<id>").
class CollectionProgressController extends StateNotifier<Map<String, CollectionProgress>> {
  CollectionProgressController() : super(const {}) {
    _load();
  }

  static const _prefKey = 'player.collection_progress';
  static const _maxEntries = 60;

  static bool isCollection(String? route) =>
      route != null && (route.startsWith('/releases/') || route.startsWith('/playlists/'));

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || !mounted) return;
      final map = (jsonDecode(raw) as Map<String, dynamic>).map((k, v) {
        final j = v as Map<String, dynamic>;
        return MapEntry(k, (
          recordingId: j['id'] as String,
          title: j['t'] as String? ?? '',
          index: j['i'] as int? ?? 0,
          total: j['n'] as int? ?? 0,
          positionMs: j['p'] as int? ?? 0,
        ));
      });
      state = {...map, ...state};
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey,
        jsonEncode({
          for (final e in state.entries)
            e.key: {'id': e.value.recordingId, 't': e.value.title, 'i': e.value.index, 'n': e.value.total, 'p': e.value.positionMs},
        }),
      );
    } catch (_) {}
  }

  void record(String route, CollectionProgress progress) {
    final current = state[route];
    if (current == progress) return;
    // Naposledy poslouchané na konec (nejstarší se zahazují).
    final next = {...state}..remove(route);
    next[route] = progress;
    while (next.length > _maxEntries) {
      next.remove(next.keys.first);
    }
    state = next;
    _save();
  }

  void clear(String route) {
    if (!state.containsKey(route)) return;
    state = {...state}..remove(route);
    _save();
  }
}

final collectionProgressProvider =
    StateNotifierProvider<CollectionProgressController, Map<String, CollectionProgress>>(
        (ref) => CollectionProgressController());
