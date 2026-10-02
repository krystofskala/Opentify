// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:record/record.dart';

import 'tuner_bridge.dart';

/// Nativní ladička: mikrofon přes `record` (PCM 16 bit, 48 kHz mono) a stejná
/// detekce výšky jako webový worklet (web/tuner/tuner-worklet.js): 2× biquad
/// dolní propust -> decimace na ~12 kHz -> okno 1024 vzorků, každých 256
/// McLeod Pitch Method. Zvuk zůstává v zařízení.
const _rate = 48000;
const _window = 1024;
const _hop = 256;
const _minHz = 60.0;
const _maxHz = 1400.0;
const _mpmK = 0.9;

AudioRecorder? _recorder;
StreamSubscription<Uint8List>? _sub;
void Function(String state)? _onState;
AudioPlayer? _tonePlayer;

/// Roste s každým start/stop -- stop během rozjíždějícího se startu (zavřená
/// ladička před povolením mikrofonu) jinak nechal mikrofon otevřený.
int _generation = 0;

Future<void> startTuner({
  required void Function(double hz, double clarity, double rms) onData,
  required void Function(String state) onState,
}) async {
  await stopTuner();
  final gen = ++_generation;
  final recorder = AudioRecorder();
  if (!await recorder.hasPermission()) {
    await recorder.dispose();
    throw const TunerStartException('denied');
  }
  final processor = _Processor(_rate.toDouble());
  try {
    final stream = await recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _rate,
      numChannels: 1,
      echoCancel: false,
      noiseSuppress: false,
      autoGain: false,
    ));
    _sub = stream.listen((bytes) {
      final view = ByteData.sublistView(bytes);
      final n = bytes.length ~/ 2;
      final samples = Float64List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
      }
      for (final r in processor.feed(samples)) {
        onData(r.$1, r.$2, r.$3);
      }
    });
  } catch (e) {
    await recorder.dispose();
    throw TunerStartException('unavailable', '$e');
  }
  if (gen != _generation) {
    // Mezitím zavřeno -- hned uvolnit.
    await _sub?.cancel();
    _sub = null;
    try {
      await recorder.stop();
    } catch (_) {}
    await recorder.dispose();
    return;
  }
  _recorder = recorder;
  _onState = onState;
  onState('running');
}

Future<void> stopTuner() async {
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
    _onState?.call('closed');
  }
  _onState = null;
}

Future<void> playTunerTone(double hz, double seconds) async {
  final player = _tonePlayer ??= AudioPlayer();
  await player.setAudioSource(_BytesSource(_sineWav(hz, seconds)));
  await player.play();
}

Uint8List _sineWav(double hz, double seconds) {
  const sr = 44100;
  final n = (sr * seconds).round();
  final pcm = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    // Měkký náběh a doznění, ať tón necvakne.
    final env = math.min(1.0, t / 0.02) * math.min(1.0, (seconds - t) / 0.3);
    final v = math.sin(2 * math.pi * hz * t) * 0.35 * env.clamp(0.0, 1.0);
    pcm.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  final header = ByteData(44);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, sr, Endian.little);
  header.setUint32(28, sr * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, n * 2, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcm.buffer.asUint8List()))
      .toBytes();
}

class _BytesSource extends StreamAudioSource {
  _BytesSource(this._bytes);
  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}

class _Biquad {
  _Biquad(double sampleRate, double fc, double q) {
    final w0 = 2 * math.pi * fc / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final cos = math.cos(w0);
    final a0 = 1 + alpha;
    b0 = (1 - cos) / 2 / a0;
    b1 = (1 - cos) / a0;
    b2 = (1 - cos) / 2 / a0;
    a1 = -2 * cos / a0;
    a2 = (1 - alpha) / a0;
  }

  late final double b0, b1, b2, a1, a2;
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

  double run(double x) {
    final y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    return y;
  }
}

class _Processor {
  _Processor(double sampleRate) {
    factor = math.max(1, (sampleRate / 12000).round());
    rate = sampleRate / factor;
    final fc = math.min(2600.0, rate * 0.4);
    f1 = _Biquad(sampleRate, fc, 0.54);
    f2 = _Biquad(sampleRate, fc, 1.31);
  }

  late final int factor;
  late final double rate;
  late final _Biquad f1, f2;
  int phase = 0;
  final ring = Float64List(_window);
  int write = 0, filled = 0, sinceHop = 0;
  final frame = Float64List(_window);
  final nsdf = Float64List(_window);

  List<(double, double, double)> feed(Float64List input) {
    final out = <(double, double, double)>[];
    for (var i = 0; i < input.length; i++) {
      final y = f2.run(f1.run(input[i]));
      if (++phase < factor) continue;
      phase = 0;
      ring[write] = y;
      write = (write + 1) % _window;
      if (filled < _window) filled++;
      if (++sinceHop >= _hop && filled == _window) {
        sinceHop = 0;
        out.add(_analyse());
      }
    }
    return out;
  }

  (double, double, double) _analyse() {
    var mean = 0.0;
    for (var i = 0; i < _window; i++) {
      frame[i] = ring[(write + i) % _window];
      mean += frame[i];
    }
    mean /= _window;
    var energy = 0.0;
    for (var i = 0; i < _window; i++) {
      frame[i] -= mean;
      energy += frame[i] * frame[i];
    }
    final rms = math.sqrt(energy / _window);
    if (rms < 1e-4) return (0, 0, rms);
    final (hz, clarity) = _mpm(frame, rate, nsdf);
    return (hz, clarity, rms);
  }
}

(double, double) _mpm(Float64List x, double sr, Float64List nsdf) {
  final n = x.length;
  final maxTau = math.min(n - 1, (sr / _minHz).ceil());
  final minTau = math.max(2, (sr / _maxHz).floor());
  var m = 0.0;
  for (var i = 0; i < n; i++) {
    m += 2 * x[i] * x[i];
  }
  if (m <= 1e-12) return (0, 0);
  for (var tau = 0; tau <= maxTau; tau++) {
    if (tau > 0) m -= x[tau - 1] * x[tau - 1] + x[n - tau] * x[n - tau];
    var r = 0.0;
    for (var i = 0; i < n - tau; i++) {
      r += x[i] * x[i + tau];
    }
    nsdf[tau] = m > 1e-12 ? 2 * r / m : 0;
  }
  final peaks = <int>[];
  var tau = 1;
  while (tau < maxTau && nsdf[tau] > 0) {
    tau++;
  }
  while (tau < maxTau) {
    while (tau < maxTau && nsdf[tau] <= 0) {
      tau++;
    }
    var best = -1;
    while (tau < maxTau && nsdf[tau] > 0) {
      if (best < 0 || nsdf[tau] > nsdf[best]) best = tau;
      tau++;
    }
    if (best > 0 && best >= minTau) peaks.add(best);
  }
  if (peaks.isEmpty) return (0, 0);
  var highest = 0.0;
  for (final p in peaks) {
    highest = math.max(highest, nsdf[p]);
  }
  final threshold = _mpmK * highest;
  final chosen = peaks.firstWhere((p) => nsdf[p] >= threshold);
  final a = nsdf[chosen - 1], b = nsdf[chosen], c = nsdf[chosen + 1];
  final denom = a - 2 * b + c;
  final shift = denom != 0 ? 0.5 * (a - c) / denom : 0.0;
  var period = chosen + shift;
  final clarity = b - 0.25 * (a - c) * shift;
  final mult = ((maxTau - 2) / period).floor();
  if (mult >= 2) {
    final center = (mult * period).round();
    var best = center;
    for (var t = center - 2; t <= center + 2; t++) {
      if (t > 0 && t < maxTau && nsdf[t] > nsdf[best]) best = t;
    }
    if (best > 0 && best < maxTau) {
      final a2 = nsdf[best - 1], b2 = nsdf[best], c2 = nsdf[best + 1];
      final d2 = a2 - 2 * b2 + c2;
      if (b2 > 0.5 * clarity && d2 < 0) period = (best + 0.5 * (a2 - c2) / d2) / mult;
    }
  }
  return (sr / period, math.min(1.0, clarity));
}

/// Jen pro test: výsledky detektoru pro dané vzorky.
List<(double, double, double)> detectPitchForTest(Float64List samples, double sampleRate) =>
    _Processor(sampleRate).feed(samples);
