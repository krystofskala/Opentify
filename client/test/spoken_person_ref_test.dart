import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/spoken_data.dart';

void main() {
  test('person ref folds like the server', () {
    expect(spokenPersonRef('J. R. R. Tolkien'), 'author:j r r tolkien');
    expect(spokenPersonRef('Jo Nesbø', narrator: true), 'narrator:jo nesbo');
    expect(spokenPersonRef('Zdeněk Jirotka'), 'author:zdenek jirotka');
  });
}
