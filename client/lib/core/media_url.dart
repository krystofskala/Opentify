import 'config.dart';
import 'device_token.dart';

/// Obrázky z vlastního backendu (vložené obaly z lokálních souborů) chodí
/// jako relativní `/api/v1/...` cesta -- backend neví, jestli klient přišel
/// přes IP nebo přes HTTPS adresu z `tailscale serve`. Tady se složí proti
/// originu API base URL, se kterou je appka sestavená. Absolutní URL (Deezer,
/// Cover Art Archive, Wikimedia) projdou beze změny.
String? resolveMediaUrl(String? url) {
  if (url == null || url.isEmpty || !url.startsWith('/')) return url;
  final api = Uri.parse(AppConfig.apiBaseUrl);
  final rel = Uri.parse(url);
  // Dotaz zachovat -- `?v=` u vlastního obalu playlistu je cache-busting.
  return withDeviceToken(api.replace(path: rel.path, query: rel.hasQuery ? rel.query : null, fragment: null).toString());
}

List<String> resolveMediaUrls(List<String> urls) => urls.map((u) => resolveMediaUrl(u)!).toList();
