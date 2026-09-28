import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'search_history';
const _maxEntries = 12;

/// Poslední hledané dotazy, per-zařízení (`SharedPreferences`, ne server) --
/// stejný UX vzor jako Musify's `searchHistoryNotifier` (`screens/search_page.dart`,
/// github.com/gokadzev/Musify, GPL-3.0; tam přes Hive, tady žádná lokální DB
/// v appce ještě neběží, takže `shared_preferences` stačí). Nejnovější
/// dotaz vždy první, duplicity se přesunou navrch místo zdvojení.
class SearchHistoryController extends StateNotifier<List<String>> {
  SearchHistoryController() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getStringList(_prefsKey) ?? const [];
  }

  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final next = [trimmed, ...state.where((q) => q.toLowerCase() != trimmed.toLowerCase())];
    state = next.take(_maxEntries).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, state);
  }

  Future<void> remove(String query) async {
    state = state.where((q) => q != query).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, state);
  }

  Future<void> clear() async {
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

final searchHistoryControllerProvider =
    StateNotifierProvider<SearchHistoryController, List<String>>((ref) => SearchHistoryController());
