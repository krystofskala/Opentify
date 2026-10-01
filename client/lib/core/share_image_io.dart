import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Nativní appka: obrázek / soubor do systémového sdílení (Instagram,
/// Fotky, Uložit do Souborů, AirDrop...).
Future<void> shareImage(Uint8List png, {required String fileName, String? text}) async {
  await Share.shareXFiles([XFile.fromData(png, name: fileName, mimeType: 'image/png')], text: text);
}

Future<void> shareFile(Uint8List bytes, {required String fileName, required String mimeType}) async {
  await Share.shareXFiles([XFile.fromData(bytes, name: fileName, mimeType: mimeType)]);
}
