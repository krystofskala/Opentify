import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/stall_watch.dart';

/// Hlídač záseku startu (core/stall_watch.dart): po play() do 5 s bez posunu
/// pozice -> znovu načíst, nejvýš 2×, pak chyba; rozjetí hlídání ukončí.
void main() {
  test('zaseknutý zdroj: 2× znovu načíst, pak chyba', () {
    final w = StallWatch()..newTrack();
    final actions = <String>[];
    w.arm(0, 0);
    for (var t = 0.0; t < 30000; t += 250) {
      final a = w.check(nowMs: t, positionMs: 0, wantsPlaying: true);
      if (a != 'ok') {
        actions.add(a);
        if (a == 'reload') w.arm(t, 0);
      }
    }
    expect(actions, ['reload', 'reload', 'fail']);
  });

  test('rozjede se po znovunačtení -> hlídání končí; pauza se nehlídá; nová skladba od nuly', () {
    final w = StallWatch()..newTrack();
    w.arm(0, 0);
    expect(w.check(nowMs: 5000, positionMs: 0, wantsPlaying: true), 'reload');
    w.arm(5000, 0);
    expect(w.check(nowMs: 6000, positionMs: 400, wantsPlaying: true), 'ok');
    expect(w.armed, isFalse);
    w.arm(7000, 400);
    expect(w.check(nowMs: 20000, positionMs: 400, wantsPlaying: false), 'ok');
    w.newTrack();
    expect(w.reloads, 0);
  });
}
