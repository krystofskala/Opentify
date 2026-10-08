import 'dart:typed_data';

Future<void> put(String id, Uint8List bytes, String mimeType) async {}
Future<int> putFromUrl(String id, String url) async => 0;
Future<String?> localUrl(String id) async => null;
Future<void> remove(String id) async {}
Future<void> clear() async {}
Future<({int usage, int? quota})?> estimate() async => null;
Future<void> persist() async {}
