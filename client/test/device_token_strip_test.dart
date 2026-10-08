import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/device_token.dart';

void main() {
  test('token zařízení se z adresy odstraní (i jako jediný parametr)', () {
    expect(withoutDeviceToken('https://x/api/v1/spoken/books/b/cover?t=SECRET'), 'https://x/api/v1/spoken/books/b/cover');
    expect(withoutDeviceToken('https://x/a?size=3&t=SECRET'), 'https://x/a?size=3');
    expect(withoutDeviceToken('https://x/a?size=3'), 'https://x/a?size=3');
  });
}
