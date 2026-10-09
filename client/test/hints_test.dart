import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/state/hints.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;
  late List<Hint> shown;

  HintsController make() {
    shown = [];
    return HintsController(clock: () => now, show: (h, _, __) => shown.add(h));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 10, 9, 10);
  });

  test('tip až po prahu, ne v první minutě, nejvýš jeden denně', () async {
    final c = make();
    await Future<void>.delayed(Duration.zero);
    c.signal(Hint.queueSwipe);
    c.signal(Hint.queueSwipe);
    c.signal(Hint.queueSwipe);
    expect(shown, isEmpty); // první minuta po otevření
    now = now.add(const Duration(minutes: 2));
    c.signal(Hint.queueSwipe);
    c.signal(Hint.queueSwipe);
    c.signal(Hint.queueSwipe);
    expect(shown, [Hint.queueSwipe]);
    c.signal(Hint.laterSwipe);
    c.signal(Hint.laterSwipe);
    c.signal(Hint.laterSwipe);
    expect(shown, [Hint.queueSwipe]); // dnes už byl tip
    now = now.add(const Duration(days: 1));
    c.signal(Hint.laterSwipe);
    expect(shown, [Hint.queueSwipe, Hint.laterSwipe]);
  });

  test('použitá funkce, „Už ne“ a vypnutí tip zastaví; nejvýš 2×, podruhé po 14 dnech', () async {
    final c = make();
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(minutes: 2));
    c.used(Hint.endless);
    c.signal(Hint.endless);
    c.signal(Hint.endless);
    expect(shown, isEmpty);

    c.signal(Hint.albumDownload);
    expect(shown, [Hint.albumDownload]);
    now = now.add(const Duration(days: 3));
    c.signal(Hint.albumDownload);
    expect(shown, [Hint.albumDownload]); // dřív než za 14 dní ne
    now = now.add(const Duration(days: 12));
    c.signal(Hint.albumDownload);
    expect(shown, [Hint.albumDownload, Hint.albumDownload]);
    now = now.add(const Duration(days: 30));
    c.signal(Hint.albumDownload);
    expect(shown.length, 2); // víc než 2× nikdy

    now = now.add(const Duration(days: 1));
    c.never(Hint.sleepTimer);
    c.signal(Hint.sleepTimer);
    expect(shown.length, 2);

    await c.setEnabled(false);
    c.signal(Hint.desktopKeys);
    expect(shown.length, 2);
  });
}
