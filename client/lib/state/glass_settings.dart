import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
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
final glassFrostProvider = StateNotifierProvider<GlassSliderController, double>(
    (ref) => GlassSliderController('appearance.glass_frost', 0.28));

/// Profil › Vzhled › "Síla tónu": síla výplně skla (0 = bez tónu, 1 =
/// dvojnásobná proti původnímu; výchozí 0.7 -- schváleno).
final glassTintProvider =
    StateNotifierProvider<GlassSliderController, double>((ref) => GlassSliderController('appearance.glass_tint', 0.59));

/// Profil › Vzhled › "Tmavost tónu": jak tmavá je výplň skla (výchozí 0.5 =
/// dosavadní vzhled). Odděleně od barevnosti -- tmavé sklo nemusí být sytě
/// barevné (živě: hodně barevné tmavé sklo vypadalo divně).
final glassDarknessProvider = StateNotifierProvider<GlassSliderController, double>(
    (ref) => GlassSliderController('appearance.glass_darkness', 0.77));

/// Profil › Vzhled › "Barevnost tónu": kolik barvy skladby sklo nese
/// (0 = neutrální šedá, výchozí 0.7 = dosavadní vzhled).
final glassColorfulnessProvider = StateNotifierProvider<GlassSliderController, double>(
    (ref) => GlassSliderController('appearance.glass_colorfulness', 0.44));

/// Profil › Vzhled › "Barva tónu": hlavní = převládající barva pozadí
/// (sklo ladí s pozadím), kontrastní = výrazná barva obalu (akcent). Dřív
/// vždy akcent -- u obalů, kde se liší od pozadí, pak sklo působilo cize.
class GlassTintMainController extends StateNotifier<bool> {
  GlassTintMainController() : super(true) {
    _load();
  }

  static const _prefKey = 'appearance.glass_tint_main';

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

/// `true` = hlavní barva pozadí, `false` = kontrastní (akcent).
final glassTintMainProvider = StateNotifierProvider<GlassTintMainController, bool>((ref) => GlassTintMainController());

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
  GlassToneController() : super(GlassToneMode.auto) {
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

/// Profil › Vzhled › Pozadí: "Nové (beta)" -- víc barev obalu najednou,
/// bílá/černá jako světlo, plynulejší reakce na scroll a jemné dýchání podle
/// hlasitosti skladby. Klasické pozadí zůstává výchozí a beze změny.
class BackgroundV2Controller extends StateNotifier<bool> {
  BackgroundV2Controller() : super(false) {
    _load();
  }

  static const _prefKey = 'appearance.background_v2';

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

final backgroundV2Provider = StateNotifierProvider<BackgroundV2Controller, bool>((ref) => BackgroundV2Controller());

/// Profil › Vzhled › "Systémové sklo" (jen iOS appka): plovoucí lišty
/// (tab bar, kapsle, mini přehrávač) dostanou skutečné Liquid Glass z iOS 26
/// (`NativeGlassView` v AppDelegate.swift) místo našeho. Test, výchozí vypnuto.
class SystemGlassController extends StateNotifier<bool> {
  SystemGlassController() : super(false) {
    _load();
  }

  static const _prefKey = 'appearance.system_glass';

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

final systemGlassProvider = StateNotifierProvider<SystemGlassController, bool>((ref) => SystemGlassController());

/// Systémové sklo jde jen v nativní iOS appce (ne web, ne Android).
bool get systemGlassSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

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

/// Profil › Vzhled › "Bez skla": Liquid Glass úplně vypnuté -- každý
/// skleněný prvek (lišta, mini přehrávač, sheety, ovládání, tlačítka,
/// segmenty) je plná M3 Expressive plocha s kontrastním okrajem. Pro starší
/// iPhony (bez rozmazání a lomu je to výrazně lehčí) a horší zrak (plné
/// plochy = vyšší kontrast textu).
///
/// Nastavení TOHOTO zařízení (nesynchronizuje se profilem): ve webu je sklo
/// výchozí vypnuté (prohlížeč ho kreslí pomalu, i v Chromu), v appce zapnuté.
class GlassOffController extends StateNotifier<bool> {
  GlassOffController() : super(kIsWeb) {
    _load();
  }

  // Nový klíč: starý `appearance.glass_off` se synchronizoval mezi zařízeními.
  static const _prefKey = 'appearance.glass_off_device';

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

final glassOffProvider = StateNotifierProvider<GlassOffController, bool>((ref) => GlassOffController());

/// Web v prohlížeči telefonu (iPhone / Android) -- nejpomalejší prostředí
/// appky (CanvasKit bez nativního vykreslování).
bool get isMobileWeb =>
    kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

/// "Omezit animace" na tomhle zařízení (pro lidi, kterým pohyb vadí) --
/// navíc k systémovému nastavení; zapnuté = celá appka jako se systémovým
/// omezením pohybu (`MediaQuery.disableAnimations`, viz app.dart). Na webu
/// v telefonu výchozí zapnuté, i s pozadím, které stojí (uživatel 7. 10.:
/// „hodně se to tam sekalo“); kdo si ho přepnul, má svou volbu.
class ReducedMotionController extends StateNotifier<bool> {
  ReducedMotionController() : super(isMobileWeb) {
    _load();
  }

  static const _prefKey = 'appearance.reduced_motion_device';

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

final reducedMotionProvider = StateNotifierProvider<ReducedMotionController, bool>((ref) => ReducedMotionController());

// Výchozí hodnoty = nastavení majitele z telefonu (2026-10-03, profil "Já").

/// Nastavení skla pro celý strom (`GlassContainer` je bez Riverpodu).
class GlassSettings extends InheritedWidget {
  const GlassSettings({
    super.key,
    this.frost = 0.5,
    this.tint = 0.5,
    this.tintColor,
    this.darkness = 0.5,
    this.colorfulness = 0.7,
    this.tone = GlassToneMode.auto,
    this.grain = false,
    this.fineGrain = false,
    required this.glassButtons,
    this.liquid = false,
    this.solid = false,
    this.system = false,
    required super.child,
  });

  /// Systémové Liquid Glass (iOS) pro prvky s `GlassContainer.systemGlass`.
  final bool system;

  /// Jezdce 0..1, výchozí 0.5 (násobitel 2× hodnota).
  final double frost;
  final double tint;

  /// Barva tónu místo neutrální (barva skladby), nebo `null`.
  final Color? tintColor;

  /// Jezdce 0..1: tmavost výplně a kolik barvy skladby nese.
  final double darkness;
  final double colorfulness;
  final GlassToneMode tone;
  final bool grain;

  /// "Jemnější zrno" -- zrno na skle pak taky slabší.
  final bool fineGrain;
  final bool glassButtons;
  final bool liquid;

  /// "Bez skla": plné plochy místo skla (viz `glassOffProvider`).
  final bool solid;

  /// Zkratka pro prvky, co si sklo kreslí samy (kapka tab baru, segmenty).
  static bool solidOf(BuildContext context) => maybeOf(context)?.solid ?? false;

  static GlassSettings? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlassSettings>();

  /// Stejné nastavení, jen jiný tón skla pro podstrom.
  static Widget withTone(BuildContext context, GlassToneMode tone, Widget child) {
    final s = maybeOf(context);
    if (s == null || s.tone == tone) return child;
    return GlassSettings(
      frost: s.frost,
      tint: s.tint,
      tintColor: s.tintColor,
      darkness: s.darkness,
      colorfulness: s.colorfulness,
      tone: tone,
      grain: s.grain,
      fineGrain: s.fineGrain,
      glassButtons: s.glassButtons,
      liquid: s.liquid,
      solid: s.solid,
      system: s.system,
      child: child,
    );
  }

  static int? _coarse(Color? c) =>
      c == null ? null : ((c.r * 31).round() << 10) | ((c.g * 31).round() << 5) | (c.b * 31).round();

  @override
  bool updateShouldNotify(GlassSettings old) =>
      old.frost != frost ||
      old.tint != tint ||
      // Přechod barvy skladby (2,8 s) mění tón každý snímek -- přestavět
      // všechna skla jen při znatelném posunu (~3 % na kanál), ne 170x.
      _coarse(old.tintColor) != _coarse(tintColor) ||
      old.darkness != darkness ||
      old.colorfulness != colorfulness ||
      old.tone != tone ||
      old.grain != grain ||
      old.fineGrain != fineGrain ||
      old.glassButtons != glassButtons ||
      old.system != system ||
      old.liquid != liquid ||
      old.solid != solid;
}
