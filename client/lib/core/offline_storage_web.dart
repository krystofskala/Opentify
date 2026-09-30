import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const _cacheName = 'opentify-offline-v1';
String _key(String id) => '${web.window.location.origin}/__offline__/$id';

// Jedna blob URL na skladbu (přehrávač ji může dostat opakovaně).
final Map<String, String> _blobUrls = {};

Future<web.Cache> _open() => web.window.caches.open(_cacheName).toDart;

Future<void> put(String id, Uint8List bytes, String mimeType) async {
  final cache = await _open();
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final response = web.Response(
    blob,
    web.ResponseInit(headers: web.Headers()..set('Content-Type', mimeType)),
  );
  await cache.put(_key(id).toJS, response).toDart;
}

Future<String?> localUrl(String id) async {
  final existing = _blobUrls[id];
  if (existing != null) return existing;
  try {
    final cache = await _open();
    final match = await cache.match(_key(id).toJS).toDart;
    if (match == null) return null;
    final blob = await match.blob().toDart;
    final url = web.URL.createObjectURL(blob);
    _blobUrls[id] = url;
    return url;
  } catch (_) {
    return null;
  }
}

Future<void> remove(String id) async {
  final url = _blobUrls.remove(id);
  if (url != null) web.URL.revokeObjectURL(url);
  try {
    final cache = await _open();
    await cache.delete(_key(id).toJS).toDart;
  } catch (_) {}
}

Future<void> clear() async {
  for (final url in _blobUrls.values) {
    web.URL.revokeObjectURL(url);
  }
  _blobUrls.clear();
  try {
    await web.window.caches.delete(_cacheName).toDart;
  } catch (_) {}
}

Future<({int usage, int? quota})?> estimate() async {
  try {
    final est = await web.window.navigator.storage.estimate().toDart;
    return (usage: est.usage.toInt(), quota: est.quota.toInt());
  } catch (_) {
    return null;
  }
}

Future<void> persist() async {
  try {
    await web.window.navigator.storage.persist().toDart;
  } catch (_) {}
}
