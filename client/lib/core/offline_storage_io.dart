import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

// Nativní appka: soubory v dokumentech appky (iOS je nezálohuje do iCloudu
// automaticky jen z Caches -- dokumenty zůstávají, dokud je uživatel nesmaže).
Future<Directory> _dir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/offline');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

// iOS přehrávač (AVPlayer) pozná formát podle přípony -- dřív ".audio"
// a lokální kopie by nešla přehrát.
const _exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav', 'audio'];

String _extFor(String mimeType) => switch (mimeType) {
      'audio/mpeg' => 'mp3',
      'audio/mp4' || 'audio/x-m4a' => 'm4a',
      'audio/aac' => 'aac',  // přehrávač iOS pozná formát podle přípony
      'audio/flac' || 'audio/x-flac' => 'flac',
      'audio/ogg' => 'ogg',
      'audio/opus' => 'opus',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => 'm4a',
    };

Future<File?> _existing(String id) async {
  final dir = await _dir();
  for (final ext in _exts) {
    final f = File('${dir.path}/$id.$ext');
    if (f.existsSync()) return f;
  }
  return null;
}

Future<void> put(String id, Uint8List bytes, String mimeType) async {
  await remove(id);
  final file = File('${(await _dir()).path}/$id.${_extFor(mimeType)}');
  await file.writeAsBytes(bytes, flush: true);
}

/// Stream z adresy po kouscích do souboru (díl knihy může mít stovky MB --
/// dřív se celý načetl do paměti). Nejdřív do `.part`, pak přejmenovat.
Future<int> putFromUrl(String id, String url) async {
  // Zaseknuté spojení nesmí navždy obsadit frontu stahování (audit 8. 10.).
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
    final mime = (response.headers.contentType?.mimeType ?? 'audio/mp4').toLowerCase();
    await remove(id);
    final dir = await _dir();
    final part = File('${dir.path}/$id.part');
    final sink = part.openWrite();
    try {
      // Bez dat 60 s = výpadek (ne nekonečné čekání).
      await response.timeout(const Duration(seconds: 60)).pipe(sink);
    } catch (_) {
      await sink.close().catchError((Object _) {});
      if (part.existsSync()) await part.delete();
      rethrow;
    }
    final file = await part.rename('${dir.path}/$id.${_extFor(mime)}');
    return file.lengthSync();
  } finally {
    client.close();
  }
}

Future<String?> localUrl(String id) async => (await _existing(id))?.uri.toString();

Future<void> remove(String id) async {
  final file = await _existing(id);
  if (file != null) await file.delete();
}

Future<void> clear() async {
  final dir = await _dir();
  if (dir.existsSync()) await dir.delete(recursive: true);
}

Future<({int usage, int? quota})?> estimate() async {
  final dir = await _dir();
  var usage = 0;
  for (final f in dir.listSync().whereType<File>()) {
    usage += f.lengthSync();
  }
  return (usage: usage, quota: null);
}

Future<void> persist() async {}
