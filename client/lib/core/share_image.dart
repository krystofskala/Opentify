import 'dart:typed_data';

import 'share_image_stub.dart' if (dart.library.js_interop) 'share_image_web.dart' as impl;

/// Sdílí PNG (Wrapped karta) systémovým sdílením -- na iPhonu rovnou do
/// Instagram stories, WhatsAppu, Fotek... Kde to nejde (PC), stáhne soubor.
/// Volat hned z obsluhy klepnutí -- Safari sdílení jinak odmítne.
Future<void> shareImage(Uint8List png, {required String fileName, String? text}) =>
    impl.shareImage(png, fileName: fileName, text: text);
