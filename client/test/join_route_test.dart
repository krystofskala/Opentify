import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/join_route.dart';

void main() {
  test('kód pozvánky z odkazu', () {
    expect(joinCodeFromRoute('/join/AbC123'), 'AbC123');
    expect(joinCodeFromRoute('/?join=XYZ'), 'XYZ');
    expect(joinCodeFromRoute('/releases/1'), isNull);
    expect(joinCodeFromRoute('/join/'), isNull);
    expect(joinCodeFromRoute('/'), isNull);
  });
}
