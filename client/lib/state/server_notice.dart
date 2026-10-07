import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart' show appMessengerKey;
import '../core/realtime_event.dart';
import '../widgets/toast.dart';
import 'audio_player_controller.dart';
import 'providers.dart';

/// Plánovaný restart serveru (nasazení nové verze): server ho ohlásí
/// (`app.tools.announce_restart`), appka řekne, co se děje, a po
/// znovupřipojení potvrdí, že je hotovo -- krátká pauza v hudbě pak
/// nevypadá jako chyba. Přehrávání naváže samo (`audio_player_controller`).
final serverRestartNoticeProvider = Provider<void>((ref) {
  final client = ref.watch(realtimeClientProvider);
  var restarting = false;
  final sub = client.events.listen((event) {
    if (event is UnknownEvent && event.type == 'server.restarting') {
      restarting = true;
      ref.read(audioPlayerControllerProvider.notifier).serverRestarting();
      showToast(
        appMessengerKey.currentState,
        'Opentify se teď na chvilku aktualizuje – hudba se může na pár sekund zastavit, pak sama naváže.',
        duration: const Duration(seconds: 10),
      );
    }
  });
  client.addConnectListener(() {
    if (!restarting) return;
    restarting = false;
    showToast(appMessengerKey.currentState, 'Hotovo – Opentify je aktualizovaný.');
  });
  ref.onDispose(sub.cancel);
});
