import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/realtime_event.dart' show UnknownEvent;
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import 'spoken_data.dart';

/// Kniha, která se ještě stahuje, hraje od prvních dílů -- díly, které
/// dorazí během poslechu, se doplní do fronty za ty, co v ní už jsou (dřív
/// se nepřidaly a kniha skončila u posledního dílu staženého při startu;
/// audit přehrávače 8. 10.). Spouští se ze zpráv `spoken.book` (stav
/// stahování), nejvýš jednou za 10 s na knihu.
final spokenQueueSyncProvider = Provider<SpokenQueueSync>((ref) {
  final sync = SpokenQueueSync(ref);
  final sub = ref.watch(realtimeClientProvider).events.listen((e) {
    if (e is UnknownEvent && e.type == 'spoken.book') sync._onBook(e.payload);
  });
  ref.onDispose(() {
    sub.cancel();
    sync._dispose();
  });
  return sync;
});

class SpokenQueueSync {
  SpokenQueueSync(this._ref);
  final Ref _ref;
  final Map<String, Timer> _pending = {};

  void _dispose() {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
  }

  void _onBook(Map<String, dynamic> payload) {
    final bookId = payload['id'] as String?;
    if (bookId == null || !_inQueue(bookId)) return;
    _pending[bookId] ??= Timer(const Duration(seconds: 10), () {
      _pending.remove(bookId);
      unawaited(_sync(bookId));
    });
  }

  bool _inQueue(String bookId) => _ref
      .read(audioPlayerControllerProvider)
      .queue
      .any((q) => AudioPlayerController.spokenParts(q.recordingId)?.bookId == bookId);

  Future<void> _sync(String bookId) async {
    try {
      final json = await _ref.read(apiClientProvider).getJson('/spoken/books/$bookId');
      final book = SpokenBook.fromJson(json);
      final all = spokenQueue(book);
      final order = {for (final (i, q) in all.indexed) q.recordingId: i};
      final ctrl = _ref.read(audioPlayerControllerProvider.notifier);
      // Díly z torrentu dorážejí v libovolném pořadí: každý chybějící díl za
      // nejbližší předchozí díl téže knihy ve frontě (pořadí knihy zůstane).
      // Díly PŘED prvním zařazeným se nepřidávají -- kniha mohla být zařazená
      // od uloženého místa (audit 8. 10.).
      for (final item in all) {
        final queue = _ref.read(audioPlayerControllerProvider).queue;
        if (queue.any((q) => q.recordingId == item.recordingId)) continue;
        final pos = order[item.recordingId]!;
        var after = -1;
        var afterPos = -1;
        for (final (qi, q) in queue.indexed) {
          final p = order[q.recordingId];
          if (p != null && p < pos && p > afterPos) {
            after = qi;
            afterPos = p;
          }
        }
        if (after < 0) continue;
        ctrl.insertQueueItems(after + 1, [item]);
      }
    } catch (e) {
      debugPrint('SpokenQueueSync: $e');
    }
  }
}
