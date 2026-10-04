import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/profile_prefs.dart';
import 'auth_controller.dart' show profilePrefsReady;

const _prefsKey = 'search_history';
const _maxEntries = 12;

/// Poslední hledané dotazy, per-zařízení (`SharedPreferences`, ne server) --
/// stejný UX vzor jako Musify's `searchHistoryNotifier` (`screens/search_page.dart`,
/// github.com/gokadzev/Musify, GPL-3.0; tam přes Hive, tady žádná lokální DB
/// v appce ještě neběží, takže `shared_preferences` stačí). Nejnovější
/// dotaz vždy první, duplicity se přesunou navrch místo zdvojení.
class SearchHistoryController extends StateNotifier<List<String>> {
  SearchHistoryController(this._ref) : super(const []) {
    _load();
  }

  final Ref _ref;
  // Historie patří profilu -- starý kontroler po přepnutí nezapisuje.
  final _prefsGeneration = profilePrefsGeneration;

  Future<void> _load() async {
    await profilePrefsReady(_ref);
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    // Odkazy (Spotify/Apple Music/…) do historie nepatří -- uklidit i staré.
    // Spojit s tím, co se mezitím (než odpověděl server) stihlo vyhledat.
    final saved = (prefs.getStringList(_prefsKey) ?? const []).where((q) => !_isLink(q));
    state = [...state, ...saved.where((q) => !state.any((s) => s.toLowerCase() == q.toLowerCase()))]
        .take(_maxEntries)
        .toList();
  }

  Future<void> _store() async {
    if (_prefsGeneration != profilePrefsGeneration) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, state);
  }

  /// Vložený odkaz není hledání -- nenavrhovat ho (živě: dlouhá Apple Music
  /// adresa pořád visela v návrzích).
  static bool _isLink(String text) =>
      RegExp(r'^(https?://|www\.|spotify:)|\.(com|net|cz|link|be)/', caseSensitive: false).hasMatch(text.trim());

  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || _isLink(trimmed)) return;
    final next = [trimmed, ...state.where((q) => q.toLowerCase() != trimmed.toLowerCase())];
    state = next.take(_maxEntries).toList();
    await _store();
  }

  Future<void> remove(String query) async {
    state = state.where((q) => q != query).toList();
    await _store();
  }

  Future<void> clear() async {
    state = const [];
    if (_prefsGeneration != profilePrefsGeneration) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

final searchHistoryControllerProvider =
    StateNotifierProvider<SearchHistoryController, List<String>>((ref) => SearchHistoryController(ref));
