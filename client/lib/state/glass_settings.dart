import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Profil › Vzhled › "Průhlednost skla": 0 = dnešní mléčné sklo, 1 = skoro
/// čiré (méně rozmazání i výplně). Platí pro všechny skleněné prvky.
class GlassClarityController extends StateNotifier<double> {
  GlassClarityController() : super(0) {
    _load();
  }

  static const _prefKey = 'appearance.glass_clarity';

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

final glassClarityProvider =
    StateNotifierProvider<GlassClarityController, double>((ref) => GlassClarityController());

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
    required this.clarity,
    required this.glassButtons,
    this.liquid = false,
    required super.child,
  });

  final double clarity;
  final bool glassButtons;
  final bool liquid;

  static GlassSettings? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlassSettings>();

  static double clarityOf(BuildContext context) => maybeOf(context)?.clarity ?? 0;

  @override
  bool updateShouldNotify(GlassSettings old) =>
      old.clarity != clarity || old.glassButtons != glassButtons || old.liquid != liquid;
}
