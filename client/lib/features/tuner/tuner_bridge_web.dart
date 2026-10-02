import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'tuner_bridge.dart';

@JS('opentifyTuner')
external _TunerJs? get _tunerJs;

extension type _TunerJs._(JSObject _) implements JSObject {
  external JSPromise<JSString> start(JSFunction onData, JSFunction onState);
  external JSPromise<JSAny?> stop();
  external void playTone(double hz, double seconds);
}

Future<void>? _loading;

/// tuner.js se načte až při prvním otevření ladičky (ne při startu appky).
Future<void> _ensureLoaded() {
  if (_tunerJs != null) return Future.value();
  return _loading ??= () {
    final done = Completer<void>();
    final script = web.HTMLScriptElement()..src = 'tuner/tuner.js';
    script.onload = ((web.Event _) => done.complete()).toJS;
    script.onerror = ((web.Event _) {
      _loading = null;
      done.completeError(const TunerStartException('unsupported', 'tuner.js se nenačetl'));
    }).toJS;
    web.document.head!.append(script);
    return done.future;
  }();
}

Future<void> startTuner({
  required void Function(double hz, double clarity, double rms) onData,
  required void Function(String state) onState,
}) async {
  final gen = ++_generation;
  await _ensureLoaded();
  final js = _tunerJs;
  if (js == null) throw const TunerStartException('unsupported');
  try {
    await js
        .start(
          ((double hz, double clarity, double rms) => onData(hz, clarity, rms)).toJS,
          ((String state) => onState(state)).toJS,
        )
        .toDart;
  } catch (e) {
    final text = e.toString();
    // DOMException jména: NotAllowedError (zamítnuto), NotFoundError /
    // NotReadableError (žádný / obsazený mikrofon).
    if (text.contains('NotAllowed') || text.contains('Permission') || text.contains('denied')) {
      throw TunerStartException('denied', text);
    }
    if (text.contains('NotFound') || text.contains('NotReadable') || text.contains('Overconstrained')) {
      throw TunerStartException('unavailable', text);
    }
    if (text.contains('unsupported')) throw TunerStartException('unsupported', text);
    throw TunerStartException('other', text);
  }
  // Zavřeno během čekání na povolení mikrofonu -- jinak by zůstal zapnutý.
  if (gen != _generation) {
    try {
      await js.stop().toDart;
    } catch (_) {}
  }
}

/// Viz tuner_bridge_io.dart.
int _generation = 0;

Future<void> stopTuner() async {
  _generation++;
  final js = _tunerJs;
  if (js == null) return;
  try {
    await js.stop().toDart;
  } catch (_) {}
}

Future<void> playTunerTone(double hz, double seconds) async {
  await _ensureLoaded();
  _tunerJs?.playTone(hz, seconds);
}
