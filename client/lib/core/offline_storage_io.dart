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

Future<File> _file(String id) async => File('${(await _dir()).path}/$id.audio');

Future<void> put(String id, Uint8List bytes, String mimeType) async {
  final file = await _file(id);
  await file.writeAsBytes(bytes, flush: true);
}

Future<String?> localUrl(String id) async {
  final file = await _file(id);
  return file.existsSync() ? file.uri.toString() : null;
}

Future<void> remove(String id) async {
  final file = await _file(id);
  if (file.existsSync()) await file.delete();
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
