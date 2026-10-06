import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/profile/history_screen.dart';

void main() {
  final now = DateTime(2026, 10, 6, 0, 30);

  test('dnes, včera, letos bez roku, loni s rokem', () {
    expect(historyDayLabel(DateTime(2026, 10, 6, 0, 5), now), 'Dnes');
    expect(historyDayLabel(DateTime(2026, 10, 5, 23, 59), now), 'Včera');
    expect(historyDayLabel(DateTime(2026, 10, 4, 12), now), '4. října');
    expect(historyDayLabel(DateTime(2025, 12, 24, 20), now), '24. prosince 2025');
  });
}
