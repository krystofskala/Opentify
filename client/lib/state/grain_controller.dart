import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Jemnější zrno" (Profil › Vzhled): slabší filmové zrno pozadí -- návrh z
/// design auditu (síla ~0.08 místo 0.14). Výchozí zůstává výrazné zrno.
class FineGrainController extends StateNotifier<bool> {
  FineGrainController() : super(false) {
    _load();
  }

  static const _prefKey = 'appearance.fine_grain';

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

final fineGrainProvider = StateNotifierProvider<FineGrainController, bool>((ref) => FineGrainController());
