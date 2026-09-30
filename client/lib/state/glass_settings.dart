import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Jezdec 0..1 uložený v preferencích.
class GlassSliderController extends StateNotifier<double> {
  GlassSliderController(this._prefKey, [double initial = 0.5]) : super(initial) {
    _load();
  }

  final String _prefKey;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_prefKey);
      if (saved != null && mounted) state = saved.clamp(0.0, 1.0);
    } catch (_) {}
  }

  /// Během tažení jezdce jen stav, uložení až na konci (`save`).
  void preview(double value) => state = value.clamp(0.0, 1.0);

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefKey, state);
    } catch (_) {}
  }
}

/// Profil › Vzhled › "Mléčnost skla": síla rozmazání obsahu pod sklem
/// (0 = čiré, 1 = dvojnásobné proti původnímu; výchozí 0.1 -- schváleno).
final glassFrostProvider =
    StateNotifierProvider<GlassSliderController, double>((ref) => GlassSliderController('appearance.glass_frost', 0.1));

/// Profil › Vzhled › "Síla tónu": síla výplně skla (0 = bez tónu, 1 =
/// dvojnásobná proti původnímu; výchozí 0.7 -- schváleno).
final glassTintProvider =
    StateNotifierProvider<GlassSliderController, double>((ref) => GlassSliderController('appearance.glass_tint', 0.7));

/// Profil › Vzhled › "Tón v barvě skladby": sklo tónované barvou hrající
/// skladby (tmavý odstín v tmavém režimu, světlý ve světlém) místo neutrální
/// šedé/bílé -- lišty jsou na pozadí lépe vidět.
class GlassAccentTintController extends StateNotifier<bool> {
  GlassAccentTintController() : super(true) {
    _load();
  }

  static const _prefKey = 'appearance.glass_accent_tint';

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

/// Profil › Vzhled › "Tón skla": světlé nebo tmavé sklo nezávisle na
/// motivu appky (`auto` = podle motivu).
enum GlassToneMode { auto, light, dark }

class GlassToneController extends StateNotifier<GlassToneMode> {
  GlassToneController() : super(GlassToneMode.dark) {
    _load();
  }

  static const _prefKey = 'appearance.glass_tone';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      final mode = GlassToneMode.values.where((m) => m.name == saved).firstOrNull;
      if (mode != null && mounted) state = mode;
    } catch (_) {}
  }

  Future<void> set(GlassToneMode value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, value.name);
    } catch (_) {}
  }
}

final glassToneProvider = StateNotifierProvider<GlassToneController, GlassToneMode>((ref) => GlassToneController());

final glassAccentTintProvider =
    StateNotifierProvider<GlassAccentTintController, bool>((ref) => GlassAccentTintController());

/// Profil › Vzhled › "Skleněná tlačítka": šipka zpět a tlačítka v hlavičce
/// jako skleněné kapky s lomem místo dnešních tmavých kroužků.
class GlassButtonsController extends StateNotifier<bool> {
  GlassButtonsController() : super(false) {
    _load();
  }

  static const _prefKey = 'appearance.glass_buttons';

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

/// Profil › Vzhled › "Zrno na skle": jemná textura (stejné zrno jako
/// pozadí) na skleněných prvcích -- test, výchozí vypnuto.
class GlassGrainController extends StateNotifier<bool> {
  GlassGrainController() : super(false) {
    _load();
  }

  static const _prefKey = 'appearance.glass_grain';

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

final glassGrainProvider = StateNotifierProvider<GlassGrainController, bool>((ref) => GlassGrainController());

final glassButtonsProvider = StateNotifierProvider<GlassButtonsController, bool>((ref) => GlassButtonsController());

/// Profil › Vzhled › "Lom skla (test)": sklo mini přehrávače láme obsah pod
/// sebou shaderem nad zachyceným snímkem (`LiquidGlass`). Výchozí zapnuto,
/// dokud se testuje -- vypnout, kdyby se rozbily obaly nebo trhalo.
class LiquidGlassController extends StateNotifier<bool> {
  LiquidGlassController() : super(true) {
    _load();
  }

  static const _prefKey = 'appearance.liquid_glass_test';

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

final liquidGlassProvider = StateNotifierProvider<LiquidGlassController, bool>((ref) => LiquidGlassController());

/// Nastavení skla pro celý strom (`GlassContainer` je bez Riverpodu).
class GlassSettings extends InheritedWidget {
  const GlassSettings({
    super.key,
    this.frost = 0.5,
    this.tint = 0.5,
    this.tintColor,
    this.tone = GlassToneMode.auto,
    this.grain = false,
    this.fineGrain = false,
    required this.glassButtons,
    this.liquid = false,
    required super.child,
  });

  /// Jezdce 0..1, výchozí 0.5 (násobitel 2× hodnota).
  final double frost;
  final double tint;

  /// Barva tónu místo neutrální (barva skladby), nebo `null`.
  final Color? tintColor;
  final GlassToneMode tone;
  final bool grain;

  /// "Jemnější zrno" -- zrno na skle pak taky slabší.
  final bool fineGrain;
  final bool glassButtons;
  final bool liquid;

  static GlassSettings? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlassSettings>();


  @override
  bool updateShouldNotify(GlassSettings old) =>
      old.frost != frost ||
      old.tint != tint ||
      old.tintColor != tintColor ||
      old.tone != tone ||
      old.grain != grain ||
      old.fineGrain != fineGrain ||
      old.glassButtons != glassButtons ||
      old.liquid != liquid;
}
