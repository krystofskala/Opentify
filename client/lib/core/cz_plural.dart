/// Česká množná čísla: 1 skladba, 2–4 skladby, 0 a 5+ skladeb.
String czPlural(int n, String one, String few, String many) => n == 1
    ? one
    : n >= 2 && n <= 4
        ? few
        : many;

/// "3 skladby", "12 skladeb".
String czCount(int n, String one, String few, String many) => '$n ${czPlural(n, one, few, many)}';

String songsCount(int n) => czCount(n, 'skladba', 'skladby', 'skladeb');
String playlistsCount(int n) => czCount(n, 'playlist', 'playlisty', 'playlistů');
