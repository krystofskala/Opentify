import 'dart:typed_data';

import 'prefetch_cache_stub.dart' if (dart.library.io) 'prefetch_cache_io.dart' as impl;

/// Dočasná kopie DALŠÍ skladby v telefonu (jen nativní appka): přechod po
/// dohrání pak hraje z lokálního souboru bez čekání na síť -- i na zamčeném
/// telefonu a při přepnutí Wi-Fi <-> data. Složka mezipaměti (iOS ji smí
/// kdykoli uvolnit), nejvýš pár souborů; nesouvisí s offline skladbami.
class PrefetchCache {
  static bool get supported => impl.supported;

  /// Uloží soubor (atomicky přes dočasné jméno) a vrátí URL pro přehrávač.
  static Future<String?> put(String id, Uint8List bytes) => impl.put(id, bytes);

  /// Už uložená kopie z dřívějška (po restartu appky).
  static Future<String?> existing(String id) => impl.existing(id);

  static Future<void> remove(String id) => impl.remove(id);
}
