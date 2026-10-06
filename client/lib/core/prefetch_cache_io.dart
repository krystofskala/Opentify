import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

const supported = true;

// Nejvýš tolik souborů / bajtů -- nejstarší (podle zápisu) se mažou.
const _maxFiles = 6;
const _maxBytes = 200 * 1024 * 1024;

Future<Directory> _dir() async {
  final base = await getTemporaryDirectory();
  final dir = Directory('${base.path}/prefetch');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

// AVPlayer pozná formát podle přípony (viz offline_storage_io.dart).
String _ext(Uint8List b) {
  if (b.length > 12 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') return 'm4a';
  if (b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == 'OggS') return 'ogg';
  if (b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == 'fLaC') return 'flac';
  return 'mp3';
}

// Kapitola / epizoda má v id dvojtečky (`sp:kniha:soubor`) -- do jména souboru ne.
String _name(String id) => id.replaceAll(':', '_');

Future<File?> _find(String id) async {
  id = _name(id);
  final dir = await _dir();
  for (final ext in const ['mp3', 'm4a', 'flac', 'ogg']) {
    final f = File('${dir.path}/$id.$ext');
    if (f.existsSync()) return f;
  }
  return null;
}

Future<String?> put(String id, Uint8List bytes) async {
  id = _name(id);
  final dir = await _dir();
  final tmp = File('${dir.path}/$id.part');
  await tmp.writeAsBytes(bytes, flush: true);
  final file = await tmp.rename('${dir.path}/$id.${_ext(bytes)}');
  await _prune(dir, keep: file.path);
  return file.uri.toString();
}

Future<String?> existing(String id) async => (await _find(id))?.uri.toString();

Future<void> remove(String id) async {
  final f = await _find(id);
  if (f != null && f.existsSync()) await f.delete();
}

Future<void> _prune(Directory dir, {required String keep}) async {
  final files = dir.listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).toList()
    ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  var total = 0;
  for (var i = 0; i < files.length; i++) {
    final f = files[i];
    total += f.lengthSync();
    if (f.path != keep && (i >= _maxFiles || total > _maxBytes)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}
