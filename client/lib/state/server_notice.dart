import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart' show appMessengerKey;
import '../core/realtime_event.dart';
import '../widgets/toast.dart';
import 'audio_player_controller.dart';
import 'providers.dart';

/// Plánovaný restart serveru (nasazení nové verze): server ho ohlásí
/// (`app.tools.announce_restart`). Většinou není poznat (hudba hraje z
/// načtené části) -- hláška jen když přehrávání opravdu zadrhne, pak i
/// „Hotovo“ po znovupřipojení. Navázání řeší `audio_player_controller`.
final serverRestartNoticeProvider = Provider<void>((ref) {
  final client = ref.watch(realtimeClientProvider);
  final sub = client.events.listen((event) {
    if (event is UnknownEvent && event.type == 'server.restarting') {
      // Bez hlášky: většinou hudba hraje dál a restart není poznat. Přehrávač
      // jen chvíli tiše zkouší znovu a ohlásí se, až když opravdu zadrhne.
      ref.read(audioPlayerControllerProvider.notifier).serverRestarting();
    }
  });
  client.addConnectListener(() {
    final player = ref.read(audioPlayerControllerProvider.notifier);
    if (!player.restartInterrupted) return;
    player.restartInterrupted = false;
    showToast(appMessengerKey.currentState, 'Hotovo – Opentify je aktualizovaný.');
  });
  ref.onDispose(sub.cancel);
});
