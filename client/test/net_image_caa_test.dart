import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/widgets/net_image.dart';

void main() {
  test('MBID from Cover Art Archive links only', () {
    expect(caaMbid('https://coverartarchive.org/release-group/1fc3-ab/front-500'), '1fc3-ab');
    expect(caaMbid('https://coverartarchive.org/release/76df-cd/front-250'), '76df-cd');
    expect(caaMbid('https://cdn-images.dzcdn.net/images/cover/x/500x500-000000-80-0-0.jpg'), isNull);
  });
}
