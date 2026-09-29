import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// Web Share API se soubory přes js_interop (package:web ho v téhle verzi nemá).
@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external JSPromise<JSAny?> share(_ShareData data);
  external bool canShare(_ShareData data);
}

extension type _ShareData._(JSObject _) implements JSObject {
  external factory _ShareData({JSArray<web.File> files, String text});
}

Future<void> shareImage(Uint8List png, {required String fileName, String? text}) async {
  final file = web.File(
    [png.toJS].toJS,
    fileName,
    web.FilePropertyBag()..type = 'image/png', // `type` je v téhle verzi jen setter z BlobPropertyBag
  );
  final data = text == null ? _ShareData(files: [file].toJS) : _ShareData(files: [file].toJS, text: text);
  final coarse = web.window.matchMedia('(pointer: coarse)').matches;
  if (coarse && _navigator.has('canShare') && _navigator.canShare(data)) {
    try {
      await _navigator.share(data).toDart;
      return;
    } catch (e) {
      if (e.toString().contains('AbortError')) return; // uživatel sdílení zavřel
    }
  }
  // PC (nebo sdílení selhalo): stáhnout jako soubor.
  final url = web.URL.createObjectURL(file);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
