import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/routing/branches.dart';

void main() {
  String? go(int branch, String location) {
    currentBranch = branch;
    return branchRedirect(Uri.parse(location));
  }

  test('detail z Domů zůstává bez předpony', () {
    expect(go(0, '/artists/a1'), isNull);
    expect(go(0, '/releases/r1?track=t'), isNull);
  });

  test('detail z jiné záložky jde do té záložky', () {
    expect(go(1, '/artists/a1'), '/search/artists/a1');
    expect(go(2, '/playlists/p1'), '/library/playlists/p1');
    expect(go(3, '/releases/r1?track=t'), '/profile/releases/r1?track=t');
  });

  test('cesta už v záložce se nemění (přepnutí záložky, zpět)', () {
    expect(go(1, '/search/artists/a1'), isNull);
    expect(go(0, '/artists/a1'), isNull);
    expect(go(2, '/library'), isNull);
    expect(go(1, '/search'), isNull);
  });

  test('staré cesty sbírek Knihovny', () {
    expect(go(2, '/library/liked'), isNull);
    expect(go(2, '/library/shazam'), '/library/shazam-list');
    expect(go(0, '/library/later'), '/later');
    expect(go(1, '/library/liked'), '/search/liked');
  });

  test('celoobrazovkové trasy mimo záložky', () {
    expect(go(1, '/now-playing'), isNull);
    expect(go(1, '/shazam?start=1'), isNull);
    expect(go(2, '/wrapped/2026'), isNull);
  });

  test('unbranched', () {
    expect(unbranched('/search/playlists/p1'), '/playlists/p1');
    expect(unbranched('/library/releases/r1'), '/releases/r1');
    expect(unbranched('/library/liked'), '/liked');
    expect(unbranched('/playlists/p1'), '/playlists/p1');
    expect(unbranched('/library'), '/library');
  });
}
