import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Zrno pozadí (Profil › Vzhled): výchozí JEMNÉ zrno, nebo žádné. Dřívější
/// výrazné zrno už není (živě: jemné jako výchozí, místo plného „žádné").
final fineGrainProvider = Provider<bool>((ref) => true);

/// "Bez zrna": pozadí i sklo úplně hladké.
class NoGrainController extends StateNotifier<bool> {
  NoGrainController() : super(false) {
    _load();
  }

  static const _prefKey = 'appearance.no_grain';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
  }
}

final noGrainProvider = StateNotifierProvider<NoGrainController, bool>((ref) => NoGrainController());

/// "Poloviční zrno": stejné zrno, poloviční síla (živě: tátovi plné zrno
/// vadilo, úplně hladké nechtěl). Od 7. 10. VÝCHOZÍ pro každého, kdo si
/// nevybral jinak (uživatel: "z polovičního udělat základ").
class HalfGrainController extends StateNotifier<bool> {
  HalfGrainController() : super(true) {
    _load();
  }

  static const _prefKey = 'appearance.half_grain';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
  }
}

final halfGrainProvider = StateNotifierProvider<HalfGrainController, bool>((ref) => HalfGrainController());
