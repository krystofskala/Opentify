/// Kód pozvánky z cesty odkazu: `/join/KÓD` (odkaz z pozvánky přes `o.html`)
/// nebo `?join=KÓD` (starší odkazy). `null` = žádná pozvánka.
String? joinCodeFromRoute(String route) {
  try {
    final uri = Uri.parse(route);
    final q = uri.queryParameters['join'];
    if (q != null && q.isNotEmpty) return q;
    final seg = uri.pathSegments;
    if (seg.length == 2 && seg[0] == 'join' && seg[1].isNotEmpty) return seg[1];
  } catch (_) {}
  return null;
}
