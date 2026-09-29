import 'tuner_bridge.dart';

Future<void> startTuner({
  required void Function(double hz, double clarity, double rms) onData,
  required void Function(String state) onState,
}) async =>
    throw const TunerStartException('unsupported');

Future<void> stopTuner() async {}

Future<void> playTunerTone(double hz, double seconds) async {}
