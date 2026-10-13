import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart' show appMessengerKey;
import '../core/realtime_event.dart';
import '../widgets/toast.dart';
import 'audio_player_controller.dart';
import 'providers.dart';

/// Importy historie spuštěné z tohoto zařízení: výsledek ohlásí samy
/// (Profil), `import.done` ze serveru je pro ostatní zařízení a pro případ,
/// že se stránka mezitím obnovila.
int localImportsRunning = 0;

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
    } else if (event is UnknownEvent && event.type == 'import.done' && localImportsRunning == 0) {
      final name = switch (event.payload['platform']) {
        'ytmusic' => 'YouTube Music',
        'applemusic' => 'Apple Music',
        _ => 'Spotify',
      };
      ref.invalidate(homeProvider);
      showToast(appMessengerKey.currentState, 'Import z $name je hotový – Wrapped a mixy se přepočítají.');
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
