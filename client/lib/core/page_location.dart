import 'page_location_stub.dart' if (dart.library.js_interop) 'page_location_web.dart' as impl;

/// Kód pozvánky z adresy (`/?join=KÓD`), nebo `null`.
String? joinCodeFromUrl() => impl.joinCodeFromUrl();

/// Odebrat `?join=` z adresy (po použití -- ať ho záložka na ploše nemá).
void clearJoinFromUrl() => impl.clearJoinFromUrl();

/// Znovu načíst appku (přepnutí profilu -- všechna data jinak).
void reloadPage() => impl.reloadPage();

/// Adresa appky pro pozvánkový odkaz.
String appOrigin() => impl.appOrigin();
