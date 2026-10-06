import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/offline_storage.dart';
import '../../state/providers.dart';

/// Epizody podcastů stažené do zařízení (poslech bez internetu). Stejné
/// úložiště jako offline skladby, klíč `pc_<epizoda>`. Stahuje se jen na
/// klepnutí, přes náš server (telefon se k vydavateli nepřipojuje).
typedef PodcastOfflineState = ({Set<String> saved, Set<String> downloading});

class PodcastOfflineController extends StateNotifier<PodcastOfflineState> {
  PodcastOfflineController(this._ref) : super((saved: const {}, downloading: const {})) {
    unawaited(_load());
  }

  final Ref _ref;
  static const _key = 'podcasts.offline.v1';

  static String storageKey(String episodeId) => 'pc_$episodeId';

  Future<void> _load() async {
    try {
      final ids = (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];
      if (mounted) state = (saved: ids.toSet(), downloading: state.downloading);
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setStringList(_key, state.saved.toList());
    } catch (_) {}
  }

  bool has(String episodeId) => state.saved.contains(episodeId);

  Future<String?> localUrl(String episodeId) async =>
      has(episodeId) ? OfflineStorage.localUrl(storageKey(episodeId)) : null;

  /// `true` = staženo.
  Future<bool> download(String episodeId) async {
    if (has(episodeId) || state.downloading.contains(episodeId)) return has(episodeId);
    state = (saved: state.saved, downloading: {...state.downloading, episodeId});
    try {
      final bytes = await _ref
          .read(apiClientProvider)
          .getBytes('/podcasts/episodes/$episodeId/stream', timeout: const Duration(minutes: 15));
      await OfflineStorage.put(storageKey(episodeId), bytes, _mime(bytes));
      unawaited(OfflineStorage.persist());
      if (!mounted) return true;
      state = (saved: {...state.saved, episodeId}, downloading: {...state.downloading}..remove(episodeId));
      await _save();
      return true;
    } catch (_) {
      if (mounted) state = (saved: state.saved, downloading: {...state.downloading}..remove(episodeId));
      return false;
    }
  }

  Future<void> remove(String episodeId) async {
    state = (saved: {...state.saved}..remove(episodeId), downloading: state.downloading);
    await OfflineStorage.remove(storageKey(episodeId));
    await _save();
  }

  static String _mime(Uint8List b) {
    if (b.length > 12 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') return 'audio/mp4';
    if (b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == 'OggS') return 'audio/ogg';
    return 'audio/mpeg';
  }
}

final podcastOfflineProvider =
    StateNotifierProvider<PodcastOfflineController, PodcastOfflineState>((ref) => PodcastOfflineController(ref));
