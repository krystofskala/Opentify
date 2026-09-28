import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_repository.dart';
import 'providers.dart';

/// Množina `recordingId` v "Liked Songs" -- sdílený stav napříč appkou (Home,
/// Search, album/artist tracklisty), aby srdíčko v `TrackTile` vědělo, jestli
/// má svítit, bez vlastního volání API na každý řádek zvlášť. Načte se líně
/// při prvním přístupu (`FutureProvider`-like chování by šlo taky, ale
/// `toggle()` potřebuje měnitelný stav pro optimistickou aktualizaci UI, ne
/// jen jednorázové načtení).
class LikedSongsController extends StateNotifier<AsyncValue<Set<String>>> {
  LikedSongsController(this._repo) : super(const AsyncValue.loading()) {
    _load();
  }

  final LibraryRepository _repo;

  Future<void> _load() async {
    try {
      final playlist = await _repo.likedSongs();
      state = AsyncValue.data(playlist.items.map((r) => r.id).toSet());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  bool isLiked(String recordingId) => state.valueOrNull?.contains(recordingId) ?? false;

  /// Optimistická aktualizace -- srdíčko se přepne okamžitě, HTTP request
  /// běží na pozadí. Při chybě se stav vrátí zpátky, ať UI nelže o tom, co
  /// je fakt uložené na serveru.
  Future<void> toggle(String recordingId) async {
    final current = state.valueOrNull;
    if (current == null) return; // ještě se nenačetlo/chyba -- není z čeho vycházet
    final wasLiked = current.contains(recordingId);
    final optimistic = {...current};
    wasLiked ? optimistic.remove(recordingId) : optimistic.add(recordingId);
    state = AsyncValue.data(optimistic);

    try {
      if (wasLiked) {
        await _repo.unlikeSong(recordingId);
      } else {
        await _repo.likeSong(recordingId);
      }
    } catch (_) {
      state = AsyncValue.data(current); // rollback
    }
  }
}

final likedSongsControllerProvider =
    StateNotifierProvider<LikedSongsController, AsyncValue<Set<String>>>((ref) {
  return LikedSongsController(ref.watch(libraryRepositoryProvider));
});
