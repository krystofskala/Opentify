import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/remove_from_library.dart' show libraryRevisionProvider;
import 'providers.dart';

/// Admin: Knihovna ukazuje buď klasickou knihovnu (co si přidal), nebo
/// úplně všechno stažené na serveru (i od ostatních profilů). Server to
/// pozná z hlavičky `X-Library-Scope: all` (ostatním profilům ji ignoruje).
class LibraryScopeController extends StateNotifier<bool> {
  LibraryScopeController(this._ref) : super(false) {
    _load();
  }

  final Ref _ref;
  static const _prefKey = 'library.scope_all';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getBool(_prefKey) ?? false) && mounted) set(true, save: false);
    } catch (_) {}
  }

  Future<void> set(bool all, {bool save = true}) async {
    state = all;
    final headers = _ref.read(apiClientProvider).extraHeaders;
    all ? headers['X-Library-Scope'] = 'all' : headers.remove('X-Library-Scope');
    _ref.read(libraryRevisionProvider.notifier).state++;
    if (!save) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, all);
    } catch (_) {}
  }
}

final libraryScopeAllProvider =
    StateNotifierProvider<LibraryScopeController, bool>((ref) => LibraryScopeController(ref));

/// Id skladeb v knihovně profilu (klasická knihovna) -- pro "Přidat /
/// Odebrat z knihovny" v menu skladby.
final libraryIdsProvider = FutureProvider<Set<String>>((ref) async {
  ref.watch(libraryRevisionProvider);
  final json = await ref.watch(apiClientProvider).getJson('/library/entries');
  return {...(json['recordingIds'] as List<dynamic>).cast<String>()};
});

/// "Přidat do knihovny" -- skladba (a stáhne se, pokud ještě není).
Future<void> addTrackToLibrary(WidgetRef ref, String recordingId) async {
  await ref.read(apiClientProvider).postJson('/library/tracks/$recordingId');
  ref.read(libraryRevisionProvider.notifier).state++;
}

/// "Přidat do knihovny" -- celé album.
Future<int> addAlbumToLibrary(WidgetRef ref, String releaseId) async {
  final json = await ref.read(apiClientProvider).postJson('/library/albums/$releaseId');
  ref.read(libraryRevisionProvider.notifier).state++;
  return json['added'] as int? ?? 0;
}
