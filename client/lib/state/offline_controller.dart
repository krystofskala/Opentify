import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/offline_storage.dart';
import 'audio_player_controller.dart' show NowPlayingInfo;
import 'provisioning_controller.dart';
import 'providers.dart';

/// Skladba uložená v zařízení pro offline poslech.
typedef OfflineTrack = ({
  String id,
  String title,
  String? artist,
  String? artistId,
  String? releaseId,
  String? artworkUrl,
  int bytes,
  DateTime addedAt,
});

typedef OfflineState = ({
  Map<String, OfflineTrack> tracks,
  // Právě se stahuje / čeká ve frontě (id -> info).
  Map<String, NowPlayingInfo> pending,
});

/// Offline knihovna v TOMHLE zařízení (Knihovna › Offline). Stáhne soubor
/// ze serveru (když tam ještě není, nejdřív ho server obstará) a uloží ho
/// do zařízení; přehrávač pak hraje odtud i bez internetu.
class OfflineController extends StateNotifier<OfflineState> {
  OfflineController(this._ref) : super((tracks: const {}, pending: const {})) {
    _load();
  }

  final Ref _ref;
  static const _prefKey = 'offline.tracks';
  static const _parallel = 2;
  int _running = 0;
  final List<String> _queue = [];

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      state = (
        tracks: {
          for (final j in list)
            j['id'] as String: (
              id: j['id'] as String,
              title: j['t'] as String? ?? '',
              artist: j['a'] as String?,
              artistId: j['ai'] as String?,
              releaseId: j['r'] as String?,
              artworkUrl: j['art'] as String?,
              bytes: j['b'] as int? ?? 0,
              addedAt: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
            ),
        },
        pending: state.pending,
      );
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey,
        jsonEncode([
          for (final t in state.tracks.values)
            {
              'id': t.id,
              't': t.title,
              'a': t.artist,
              'ai': t.artistId,
              'r': t.releaseId,
              'art': t.artworkUrl,
              'b': t.bytes,
              'at': t.addedAt.toIso8601String(),
            },
        ]),
      );
    } catch (_) {}
  }

  bool has(String id) => state.tracks.containsKey(id);
  int get totalBytes => state.tracks.values.fold(0, (a, t) => a + t.bytes);

  /// Cesta/URL pro přehrávač, když je skladba v zařízení.
  Future<String?> localUrl(String id) async => has(id) ? OfflineStorage.localUrl(id) : null;

  /// Stáhnout do zařízení (skladby, které tam ještě nejsou).
  void add(List<NowPlayingInfo> infos) {
    final pending = {...state.pending};
    for (final info in infos) {
      if (has(info.recordingId) || pending.containsKey(info.recordingId)) continue;
      pending[info.recordingId] = info;
      _queue.add(info.recordingId);
    }
    state = (tracks: state.tracks, pending: pending);
    unawaited(OfflineStorage.persist());
    _pump();
  }

  void _pump() {
    while (_running < _parallel && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _running++;
      unawaited(_download(id).whenComplete(() {
        _running--;
        _pump();
      }));
    }
  }

  Future<void> _download(String id) async {
    final info = state.pending[id];
    if (info == null) return;
    try {
      await _ensureOnServer(id);
      final bytes = await _ref.read(apiClientProvider).getBytes('/tracks/$id/stream', timeout: const Duration(minutes: 5));
      if (!mounted || !state.pending.containsKey(id)) return; // mezitím zrušeno
      await OfflineStorage.put(id, bytes, _mimeOf(bytes));
      if (!mounted || !state.pending.containsKey(id)) {
        // Zrušeno během zápisu (remove/clear soubor smazaly dřív, než
        // vznikl) -- jinak by zůstal v zařízení bez záznamu a zabíral místo.
        if (!mounted || !has(id)) await OfflineStorage.remove(id);
        return;
      }
      final track = (
        id: id,
        title: info.title,
        artist: info.artistName,
        artistId: info.artistId,
        releaseId: info.releaseId,
        artworkUrl: info.artworkUrl,
        bytes: bytes.length,
        addedAt: DateTime.now(),
      );
      state = (tracks: {...state.tracks, id: track}, pending: {...state.pending}..remove(id));
      await _save();
    } catch (_) {
      if (mounted) state = (tracks: state.tracks, pending: {...state.pending}..remove(id));
    }
  }

  /// Server skladbu musí mít staženou (jinak ji nejdřív obstará).
  Future<void> _ensureOnServer(String id) async {
    final provisioning = _ref.read(provisioningControllerProvider.notifier);
    await provisioning.provision(id);
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      final s = _ref.read(provisioningControllerProvider)[id];
      if (s == null || s.isAvailable) return;
      if (s.isFailed) throw StateError('obstarání selhalo');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw TimeoutException('skladba se nestihla stáhnout na server');
  }

  static String _mimeOf(Uint8List b) {
    if (b.length > 12 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') return 'audio/mp4';
    if (b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == 'OggS') return 'audio/ogg';
    if (b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == 'fLaC') return 'audio/flac';
    return 'audio/mpeg';
  }

  Future<void> remove(String id) async {
    _queue.remove(id);
    state = (tracks: {...state.tracks}..remove(id), pending: {...state.pending}..remove(id));
    await OfflineStorage.remove(id);
    await _save();
  }

  Future<void> clear() async {
    _queue.clear();
    state = (tracks: const {}, pending: const {});
    await OfflineStorage.clear();
    await _save();
  }
}

final offlineControllerProvider =
    StateNotifierProvider<OfflineController, OfflineState>((ref) => OfflineController(ref));

/// Kolik offline data zabírají (a kolik prohlížeč/systém dovolí).
final offlineUsageProvider = FutureProvider.autoDispose<({int usage, int? quota})?>((ref) {
  ref.watch(offlineControllerProvider.select((s) => s.tracks.length));
  return OfflineStorage.estimate();
});
