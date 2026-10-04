import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_repository.dart';
import '../widgets/remove_from_library.dart' show libraryRevisionProvider;
import 'audio_player_controller.dart';
import 'providers.dart';

/// Množina `recordingId` v "Liked Songs" -- sdílený stav napříč appkou (Home,
/// Search, album/artist tracklisty), aby srdíčko v `TrackTile` vědělo, jestli
/// má svítit, bez vlastního volání API na každý řádek zvlášť. Načte se líně
/// při prvním přístupu (`FutureProvider`-like chování by šlo taky, ale
/// `toggle()` potřebuje měnitelný stav pro optimistickou aktualizaci UI, ne
/// jen jednorázové načtení).
class LikedSongsController extends StateNotifier<AsyncValue<Set<String>>> {
  LikedSongsController(this._ref, this._repo) : super(const AsyncValue.loading()) {
    _load();
    // Lajky z jiného zařízení / importu -- po návratu do appky přenačíst,
    // jinak by sada (a filtr Oblíbených) zůstala stará až do restartu.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (DateTime.now().difference(_loadedAt) > const Duration(seconds: 30)) unawaited(refresh());
    });
  }

  final Ref _ref;
  final LibraryRepository _repo;
  AppLifecycleListener? _lifecycle;
  DateTime _loadedAt = DateTime.now();
  Timer? _revisionBump;

  /// Rozběhnuté lajky/odlajky -- načtení ze serveru, které je předběhne,
  /// je nesmí přepsat (srdíčko by na chvíli zhaslo).
  final _pending = <String, bool>{};

  Future<void> _load() async {
    try {
      final playlist = await _repo.likedSongs();
      if (mounted) replaceAll(playlist.items.map((r) => r.id).toSet());
    } catch (e, st) {
      // Stará data nechat -- chyba jen u prvního načtení.
      if (mounted && !state.hasValue) state = AsyncValue.error(e, st);
    }
  }

  /// Znovu ze serveru (import, potáhnutí dolů, návrat do appky).
  Future<void> refresh() => _load();

  /// Sada ze serveru (i z načteného `likedSongsProvider`) -- rozběhnuté
  /// změny se na ni přeloží.
  void replaceAll(Set<String> ids) {
    if (!mounted) return;
    _loadedAt = DateTime.now();
    final next = {...ids};
    _pending.forEach((id, liked) => liked ? next.add(id) : next.remove(id));
    final current = state.valueOrNull;
    if (current != null && setEquals(current, next)) return;
    state = AsyncValue.data(next);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _revisionBump?.cancel();
    super.dispose();
  }

  bool isLiked(String recordingId) => state.valueOrNull?.contains(recordingId) ?? false;

  /// Po chybě načtení (server spal) zkusí seznam znovu -- jinak by srdíčka
  /// zůstala mrtvá až do restartu appky.
  Future<void> retryIfFailed() async {
    if (state.hasError) await _load();
  }

  /// Optimistická aktualizace -- srdíčko se přepne okamžitě, HTTP request
  /// běží na pozadí. Při chybě se stav vrátí zpátky, ať UI nelže o tom, co
  /// je fakt uložené na serveru. Vrací false, když se to nepovedlo.
  Future<bool> toggle(String recordingId) async => setLiked(recordingId, !isLiked(recordingId));

  Future<bool> setLiked(String recordingId, bool liked) async {
    await retryIfFailed();
    final current = state.valueOrNull;
    if (current == null) return false; // ještě se nenačetlo -- není z čeho vycházet
    if (current.contains(recordingId) == liked) return true;
    state = AsyncValue.data(liked ? {...current, recordingId} : ({...current}..remove(recordingId)));
    _pending[recordingId] = liked;
    try {
      if (liked) {
        await _repo.likeSong(recordingId);
      } else {
        await _repo.unlikeSong(recordingId);
      }
      _bumpLibraryRevision();
      return true;
    } catch (_) {
      if (!mounted) return false;
      final now = state.valueOrNull ?? current;
      state = AsyncValue.data(liked ? ({...now}..remove(recordingId)) : {...now, recordingId}); // rollback
      return false;
    } finally {
      if (_pending[recordingId] == liked) _pending.remove(recordingId);
    }
  }

  /// Server počítá oblíbené do knihovny -- Knihovna se má přenačíst, ale
  /// ne po každém z řady rychlých klepnutí (hromadné odebrání).
  void _bumpLibraryRevision() {
    _revisionBump?.cancel();
    _revisionBump = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _ref.read(libraryRevisionProvider.notifier).state++;
    });
  }

  void setLocal(String recordingId) {
    final current = state.valueOrNull;
    if (current != null) state = AsyncValue.data({...current, recordingId});
  }

  /// Jen místní stav -- server to už udělal sám (zlomené srdce odebírá
  /// z Oblíbených).
  void forget(String recordingId) {
    final current = state.valueOrNull;
    if (current != null && current.contains(recordingId)) {
      state = AsyncValue.data({...current}..remove(recordingId));
    }
  }
}

final likedSongsControllerProvider =
    StateNotifierProvider<LikedSongsController, AsyncValue<Set<String>>>((ref) {
  return LikedSongsController(ref, ref.watch(libraryRepositoryProvider));
});

/// Zlomená srdce (dlouhé podržení srdíčka): skladby, které uživatel nechce
/// slyšet -- server je vyřadí z Oblíbených i z výběrů (mixy, rádia).
class DislikedController extends StateNotifier<Set<String>> {
  DislikedController(this._ref, this._repo) : super(const {}) {
    _load();
  }

  final Ref _ref;
  final LibraryRepository _repo;

  Future<void> _load() async {
    try {
      final ids = await _repo.dislikedIds();
      if (mounted) state = ids;
    } catch (_) {}
  }

  bool isDisliked(String recordingId) => state.contains(recordingId);

  /// Zlomí srdce (a odebere z Oblíbených), nebo ho zase spraví. Vrací
  /// false, když se to na serveru nepovedlo (stav se vrátí).
  Future<bool> toggle(String recordingId) async {
    final was = state.contains(recordingId);
    state = was ? ({...state}..remove(recordingId)) : {...state, recordingId};
    final liked = _ref.read(likedSongsControllerProvider.notifier);
    final wasLiked = liked.isLiked(recordingId);
    // Server při zlomení srdce odebere i z Oblíbených -- tady jen místně.
    if (!was) {
      liked.forget(recordingId);
      _ref.read(audioPlayerControllerProvider.notifier).dropUpcoming(recordingId);
    }
    try {
      if (was) {
        await _repo.undislikeSong(recordingId);
      } else {
        await _repo.dislikeSong(recordingId);
      }
      return true;
    } catch (_) {
      state = was ? {...state, recordingId} : ({...state}..remove(recordingId));
      if (!was && wasLiked) liked.setLocal(recordingId);
      return false;
    }
  }

  /// Jen místní stav -- server zlomené srdce zrušil sám (lajk ho spraví).
  void forget(String recordingId) {
    if (state.contains(recordingId)) state = {...state}..remove(recordingId);
  }

  void restore(String recordingId) => state = {...state, recordingId};
}

final dislikedProvider = StateNotifierProvider<DislikedController, Set<String>>((ref) {
  return DislikedController(ref, ref.watch(libraryRepositoryProvider));
});
