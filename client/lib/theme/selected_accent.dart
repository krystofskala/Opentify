import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/audio_player_controller.dart';
import 'accent_color.dart';

/// Naposledy "vybraná" barva za celou relaci: barva otevřeného alba/
/// interpreta/skladby, nebo barva právě hrající skladby -- podle toho, co se
/// změnilo naposledy. `null` jen do chvíle, než uživatel poprvé něco otevře
/// nebo pustí; do té doby je pozadí vícebarevné, potom už vždy
/// monochromatické v téhle barvě (i na Domů), jak chtěl uživatel.
class SelectedAccent extends StateNotifier<Color?> {
  SelectedAccent(Ref ref) : super(null) {
    // Obojí se mění mimo build (mikroúloha v `ScreenAccent`, asynchronní
    // extrakce barvy v přehrávači), takže zápis stavu tady je bezpečný.
    ref.listen<Color?>(activeScreenAccentProvider, (_, next) {
      if (next != null) state = next;
    });
    ref.listen<Color?>(audioPlayerControllerProvider.select((s) => s.accentColor), (_, next) {
      if (next != null) state = next;
    });
  }
}

final selectedAccentProvider = StateNotifierProvider<SelectedAccent, Color?>((ref) => SelectedAccent(ref));
