import 'dart:typed_data';

import 'recorder_bridge_stub.dart' if (dart.library.js_interop) 'recorder_bridge_web.dart' as impl;

/// Nahrávání pro Open Shazam (web/shazam/recorder.js). Musí se spustit z
/// klepnutí (iOS). Vrací MIME typ nahrávky ('audio/mp4' na iPhonu).
Future<String> startRecording() => impl.startRecording();

/// Vše nahrané od začátku -- platný soubor, jde průběžně posílat.
Future<Uint8List> recordingSnapshot() => impl.recordingSnapshot();

/// Uvolní mikrofon (iOS pak vrátí zvuk na reproduktor).
Future<void> stopRecording() => impl.stopRecording();

class RecorderException implements Exception {
  const RecorderException(this.kind, [this.detail]);

  /// 'denied', 'unavailable', 'unsupported', 'other'.
  final String kind;
  final String? detail;

  @override
  String toString() => 'RecorderException($kind, $detail)';
}
