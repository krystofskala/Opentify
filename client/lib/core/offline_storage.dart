import 'dart:typed_data';

import 'offline_storage_stub.dart'
    if (dart.library.js_interop) 'offline_storage_web.dart'
    if (dart.library.io) 'offline_storage_io.dart' as impl;

/// Úložiště skladeb pro offline poslech -- v zařízení, ne na serveru.
/// Web (PWA na ploše): Cache Storage prohlížeče; nativní appka: soubory
/// v dokumentech appky.
abstract final class OfflineStorage {
  static Future<void> put(String id, Uint8List bytes, String mimeType) => impl.put(id, bytes, mimeType);

  /// URL/cesta pro přehrávač, nebo `null`, když skladba v zařízení není.
  static Future<String?> localUrl(String id) => impl.localUrl(id);

  static Future<void> remove(String id) => impl.remove(id);

  static Future<void> clear() => impl.clear();

  /// Kolik místa appka v zařízení zabírá a kolik smí (`null` = neznámé).
  static Future<({int usage, int? quota})?> estimate() => impl.estimate();

  /// Požádat systém, ať offline data nemaže při nedostatku místa (web).
  static Future<void> persist() => impl.persist();
}
