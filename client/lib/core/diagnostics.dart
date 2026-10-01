import 'diagnostics_stub.dart'
    if (dart.library.js_interop) 'diagnostics_web.dart'
    if (dart.library.io) 'diagnostics_io.dart' as impl;

/// Zápis do "černé skříňky" (web/index.html): posledních ~30 kroků (obrazovky,
/// chyby) se přiloží k hlášení o zamrznutí appky.
void diagNote(String text) => impl.diagNote(text);

/// Okamžité hlášení na server (`/api/v1/client-log`, jen log API).
void diagReport(String kind, String detail) => impl.diagReport(kind, detail);
