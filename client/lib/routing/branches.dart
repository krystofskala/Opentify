import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../widgets/player_bar.dart';

/// Každá záložka (Domů/Hledat/Knihovna/Profil) má vlastní historii: detail
/// (interpret, album, playlist, styl...) se otevírá UVNITŘ aktuální záložky,
/// tab bar zůstává vidět a klepnutím na jinou záložku se tam jde hned --
/// rozkliknutá cesta se pamatuje (jako Apple Music / Spotify).
///
/// Kód dál volá `context.push('/artists/x')`; router (`branchRedirect`) to
/// přepíše na cestu aktuální záložky (`/search/artists/x`). Domů má detaily
/// bez předpony, takže i odkazy zvenku (`/artists/x`) fungují.
const branchPrefixes = ['', '/search', '/library', '/profile'];

/// Aktuální záložka -- nastavuje `HomeShell` (před `goBranch`, ať přepnutí
/// na záložku s rozkliknutým detailem nepřepíše jeho cestu do té staré).
int currentBranch = 0;

/// První segment cest, které jsou detailem uvnitř záložky.
const detailHeads = {
  'artists',
  'blends',
  'track',
  'releases',
  'browse',
  'playlists',
  'later',
  'shared',
  'liked',
  'shazam-list',
  'verify-downloads',
  'year-in-review',
  'games',
};

// Dřívější cesty sbírek v Knihovně -> název detailu (`/shazam` je rozpoznávání).
const _legacyLibrary = {'later': 'later', 'shared': 'shared', 'liked': 'liked', 'shazam': 'shazam-list'};

/// Kam doopravdy navigovat (`null` = beze změny).
String? branchRedirect(Uri uri) {
  final segs = uri.pathSegments;
  if (segs.isEmpty) return null;
  final prefix = branchPrefixes[currentBranch];
  String? path;
  if (segs[0] == 'library' && segs.length == 2 && _legacyLibrary.containsKey(segs[1])) {
    path = '$prefix/${_legacyLibrary[segs[1]]}';
  } else if (detailHeads.contains(segs[0]) && prefix.isNotEmpty) {
    path = '$prefix${uri.path}';
  }
  if (path == null || path == uri.path) return null;
  return uri.replace(path: path).toString();
}

/// Cesta bez předpony záložky (`/search/playlists/x` -> `/playlists/x`) --
/// pro "Přehráváno z" a odkazy, které se otevřou v jiné záložce.
String unbranched(String path) {
  for (final prefix in branchPrefixes.skip(1)) {
    if (path.startsWith('$prefix/')) {
      final rest = path.substring(prefix.length);
      final head = rest.split('/').elementAtOrNull(1);
      if (head != null && detailHeads.contains(head)) return rest;
    }
  }
  return path;
}

/// Místo vlastního mini přehrávače na detailu: rezerva pro plovoucí lišty
/// záložek (přehrávač + tab bar), ať konec stránky neleží pod nimi. Mimo
/// záložky (nečekaně otevřené nad vším) zůstane vlastní přehrávač.
class ShellBarSpace extends StatelessWidget {
  const ShellBarSpace({super.key});

  @override
  Widget build(BuildContext context) {
    if (StatefulNavigationShell.maybeOf(context) == null) return const PlayerBar();
    return SizedBox(height: MediaQuery.paddingOf(context).bottom);
  }
}
