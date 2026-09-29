import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'recorder_bridge.dart';

@JS('opentifyRecorder')
external _RecorderJs? get _recorderJs;

extension type _RecorderJs._(JSObject _) implements JSObject {
  external JSPromise<JSString> start();
  external JSPromise<JSUint8Array> snapshot();
  external JSPromise<JSAny?> stop();
}

Future<void>? _loading;

Future<void> _ensureLoaded() {
  if (_recorderJs != null) return Future.value();
  return _loading ??= () {
    final done = Completer<void>();
    final script = web.HTMLScriptElement()..src = 'shazam/recorder.js';
    script.onload = ((web.Event _) => done.complete()).toJS;
    script.onerror = ((web.Event _) {
      _loading = null;
      done.completeError(const RecorderException('unsupported', 'recorder.js se nenačetl'));
    }).toJS;
    web.document.head!.append(script);
    return done.future;
  }();
}

Future<String> startRecording() async {
  await _ensureLoaded();
  final js = _recorderJs;
  if (js == null) throw const RecorderException('unsupported');
  try {
    return (await js.start().toDart).toDart;
  } catch (e) {
    final text = e.toString();
    if (text.contains('NotAllowed') || text.contains('Permission') || text.contains('denied')) {
      throw RecorderException('denied', text);
    }
    if (text.contains('NotFound') || text.contains('NotReadable')) throw RecorderException('unavailable', text);
    if (text.contains('unsupported')) throw RecorderException('unsupported', text);
    throw RecorderException('other', text);
  }
}

Future<Uint8List> recordingSnapshot() async {
  final js = _recorderJs;
  if (js == null) return Uint8List(0);
  return (await js.snapshot().toDart).toDart;
}

Future<void> stopRecording() async {
  final js = _recorderJs;
  if (js == null) return;
  try {
    await js.stop().toDart;
  } catch (_) {}
}
