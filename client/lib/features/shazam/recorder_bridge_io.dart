import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:record/record.dart';

import 'recorder_bridge.dart';

/// Nativní appka: mikrofon přes `record` jako PCM proud (16 kHz mono),
/// snímek = WAV ze všeho nahraného -- platný soubor kdykoliv během nahrávání
/// (server ho stejně převádí ffmpegem, viz backend app/recognize.py).
const _rate = 16000;

AudioRecorder? _recorder;
StreamSubscription<Uint8List>? _sub;
final BytesBuilder _pcm = BytesBuilder(copy: false);

/// Roste s každým start/stop -- zrušení/zavření během rozjíždějícího se
/// startu (jako u ladičky) jinak nechalo mikrofon zapnutý.
int _generation = 0;

Future<String> startRecording() async {
  await stopRecording();
  final gen = ++_generation;
  final recorder = AudioRecorder();
  if (!await recorder.hasPermission()) {
    await recorder.dispose();
    throw const RecorderException('denied');
  }
  if (gen != _generation) {
    await recorder.dispose();
    return 'audio/wav';
  }
  _pcm.clear();
  final StreamSubscription<Uint8List> sub;
  try {
    final stream = await recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _rate,
      numChannels: 1,
    ));
    sub = stream.listen(_pcm.add);
  } catch (e) {
    await recorder.dispose();
    throw RecorderException('unavailable', '$e');
  }
  if (gen != _generation) {
    // Mezitím zrušeno -- hned uvolnit (globální _sub/_recorder už může mít
    // novější start, proto jen vlastní).
    await sub.cancel();
    try {
      await recorder.stop();
    } catch (_) {}
    await recorder.dispose();
    if (_recorder == null) {
      try {
        await (await AudioSession.instance).configure(const AudioSessionConfiguration.music());
      } catch (_) {}
    }
    return 'audio/wav';
  }
  _sub = sub;
  _recorder = recorder;
  return 'audio/wav';
}

Future<Uint8List> recordingSnapshot() async => _wav(_pcm.toBytes());

Future<void> stopRecording() async {
  _generation++;
  await _sub?.cancel();
  _sub = null;
  final recorder = _recorder;
  _recorder = null;
  if (recorder != null) {
    try {
      await recorder.stop();
    } catch (_) {}
    await recorder.dispose();
    // iOS: zpátky na přehrávání hudby (reproduktor), ne nahrávací režim.
    try {
      await (await AudioSession.instance).configure(const AudioSessionConfiguration.music());
    } catch (_) {}
  }
}

Uint8List _wav(Uint8List pcm) {
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, _rate, Endian.little);
  header.setUint32(28, _rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .toBytes();
}
