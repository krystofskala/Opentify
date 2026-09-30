import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/remove_from_library.dart' show libraryRevisionProvider;
import 'providers.dart';

/// Pohled Knihovny (zatím jen admin): klasická knihovna, co si stáhl, nebo
/// celý server. Server to pozná z hlavičky `X-Library-Scope`.
enum LibraryScope { mine, downloaded, all }

class LibraryScopeController extends StateNotifier<LibraryScope> {
  LibraryScopeController(this._ref) : super(LibraryScope.mine) {
    _load();
  }

  final Ref _ref;
  static const _prefKey = 'library.scope';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = LibraryScope.values.where((v) => v.name == prefs.getString(_prefKey)).firstOrNull;
      if (saved != null && saved != LibraryScope.mine && mounted) set(saved, save: false);
    } catch (_) {}
  }

  Future<void> set(LibraryScope scope, {bool save = true}) async {
    state = scope;
    final headers = _ref.read(apiClientProvider).extraHeaders;
    scope == LibraryScope.mine ? headers.remove('X-Library-Scope') : headers['X-Library-Scope'] = scope.name;
    _ref.read(libraryRevisionProvider.notifier).state++;
    if (!save) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, scope.name);
    } catch (_) {}
  }
}

final libraryScopeProvider =
    StateNotifierProvider<LibraryScopeController, LibraryScope>((ref) => LibraryScopeController(ref));

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
