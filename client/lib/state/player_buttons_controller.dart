import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tlačítka spodní řady velkého přehrávače -- uživatel si vybere až 5
/// (Profil / ⋯ v přehrávači › Upravit tlačítka).
enum PlayerButton {
  shuffle('Náhodně', Symbols.shuffle_rounded),
  lyrics('Text', Symbols.lyrics_rounded),
  queue('Fronta', Symbols.queue_music_rounded),
  repeat('Opakování', Symbols.repeat_rounded),
  like('Oblíbené', Symbols.favorite_rounded),
  later('Na později', Symbols.schedule_rounded),
  radio('Rádio', Symbols.radio_rounded),
  share('Sdílet', Symbols.ios_share_rounded),
  playlist('Do playlistu', Symbols.playlist_add_rounded),
  devices('Zařízení', Symbols.devices_rounded);

  const PlayerButton(this.label, this.icon);

  final String label;
  final IconData icon;
}

const maxPlayerButtons = 5;
const defaultPlayerButtons = [
  PlayerButton.shuffle,
  PlayerButton.lyrics,
  PlayerButton.queue,
  PlayerButton.repeat,
  PlayerButton.like,
];

final playerButtonsProvider =
    StateNotifierProvider<PlayerButtonsController, List<PlayerButton>>((ref) => PlayerButtonsController());

class PlayerButtonsController extends StateNotifier<List<PlayerButton>> {
  PlayerButtonsController() : super(defaultPlayerButtons) {
    _load();
  }

  static const _prefKey = 'player.buttons.v1';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_prefKey);
      if (saved == null || !mounted) return;
      final buttons = [
        for (final name in saved)
          if (PlayerButton.values.where((b) => b.name == name).firstOrNull case final b?) b,
      ];
      if (buttons.isNotEmpty) state = buttons.take(maxPlayerButtons).toList();
    } catch (_) {}
  }

  Future<void> set(List<PlayerButton> buttons) async {
    state = buttons.take(maxPlayerButtons).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, [for (final b in state) b.name]);
    } catch (_) {}
  }
}
