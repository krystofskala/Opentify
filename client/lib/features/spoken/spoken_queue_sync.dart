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
      final state = _ref.read(audioPlayerControllerProvider);
      final have = {for (final q in state.queue) q.recordingId};
      final missing = [for (final i in spokenQueue(book)) if (!have.contains(i.recordingId)) i];
      if (missing.isEmpty) return;
      // Za poslední díl téhle knihy ve frontě (hudba za knihou zůstane za ní).
      final last = state.queue.lastIndexWhere((q) => AudioPlayerController.spokenParts(q.recordingId)?.bookId == bookId);
      if (last < 0) return;
      _ref.read(audioPlayerControllerProvider.notifier).insertQueueItems(last + 1, missing);
    } catch (e) {
      debugPrint('SpokenQueueSync: $e');
    }
  }
}
