import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../widgets/glass/glass_button.dart';

/// Režim appky: hudba, nebo mluvené slovo (audioknihy). Přepíná celé Domů,
/// Hledání i Knihovnu; přehrávač je společný. Pamatuje si ho zařízení,
/// výchozí je hudba.
enum AppMode { music, spoken }

class AppModeController extends StateNotifier<AppMode> {
  AppModeController() : super(AppMode.music) {
    _load();
  }

  static const _key = 'app.mode';

  Future<void> _load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      if (saved == AppMode.spoken.name && mounted) state = AppMode.spoken;
    } catch (_) {}
  }

  Future<void> toggle() async {
    state = state == AppMode.music ? AppMode.spoken : AppMode.music;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, state.name);
    } catch (_) {}
  }
}

final appModeProvider = StateNotifierProvider<AppModeController, AppMode>((ref) => AppModeController());

/// Přepínač režimu vpravo nahoře na Domů, v Hledání a v Knihovně (všude na
/// stejném místě). Ikona ukazuje, ve kterém režimu jsi: nota, nebo kniha.
class AppModeToggle extends ConsumerWidget {
  const AppModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    final spoken = mode == AppMode.spoken;
    // Vždy úplně vpravo. V hudbě neutrální sklo, v mluveném slově plná
    // barva -- jiný režim je vidět na první pohled a nesplývá s vedlejšími
    // přepínači (Jen moje knihovna, rozsah knihovny).
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.md),
      child: GlassIconButton(
        icon: spoken ? Symbols.menu_book_rounded : Symbols.music_note_rounded,
        tooltip: spoken ? 'Mluvené slovo – přepnout na hudbu' : 'Hudba – přepnout na mluvené slovo',
        style: spoken ? GlassButtonStyle.prominent : GlassButtonStyle.glass,
        size: GlassTokens.compactControlHeight,
        iconSize: 20,
        onPressed: () => ref.read(appModeProvider.notifier).toggle(),
      ),
    );
  }
}

/// Kořen záložky podle režimu.
class ModeSwitch extends ConsumerWidget {
  const ModeSwitch({super.key, required this.music, required this.spoken});

  final Widget music;
  final Widget spoken;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(appModeProvider) == AppMode.spoken ? spoken : music;
}
