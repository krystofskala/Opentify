import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'providers.dart';

/// Skladby, které profil aspoň jednou poslechl celé (>= 90 % délky
/// skutečně odehráno, viz `AudioPlayerController._trackScrobble`, plus
/// historie ze Spotify). V seznamech mají nenápadnou trvalou značku.
class HeardController extends StateNotifier<Set<String>> {
  HeardController(this._ref) : super(const {}) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final json = await _ref.read(apiClientProvider).getJson('/library/heard');
      if (mounted) state = {...state, ...(json['recordingIds'] as List<dynamic>).cast<String>()};
    } catch (_) {}
  }

  Future<void> mark(String recordingId) async {
    if (state.contains(recordingId)) return;
    state = {...state, recordingId};
    try {
      await _ref.read(apiClientProvider).postJson('/library/heard/$recordingId');
    } catch (_) {}
  }
}

/// Při přepnutí profilu (admin) se načte znovu -- jen při změně profilu, ne
/// při každém obnovení `/auth/me` (zahodilo by značky a znovu je stahovalo).
final heardProvider = StateNotifierProvider<HeardController, Set<String>>((ref) {
  ref.watch(authProvider.select((a) => a.valueOrNull?.acting?.id ?? a.valueOrNull?.user?.id));
  return HeardController(ref);
});
