import 'tuner_bridge_stub.dart'
    if (dart.library.js_interop) 'tuner_bridge_web.dart'
    if (dart.library.io) 'tuner_bridge_io.dart' as impl;

/// Mikrofon ladičky (web/tuner/tuner.js + tuner-worklet.js). Zvuk se
/// zpracovává jen v zařízení -- nic se neodesílá.
///
/// `onData` dostává surové odhady detektoru (~47×/s), `onState` stav
/// AudioContextu ('running', 'suspended', 'interrupted', 'closed').
/// Musí se volat z klepnutí (iOS pustí mikrofon a zvuk jen z gesta).
Future<void> startTuner({
  required void Function(double hz, double clarity, double rms) onData,
  required void Function(String state) onState,
}) =>
    impl.startTuner(onData: onData, onState: onState);

/// Uvolní mikrofon a zvukový kontext (iOS pak vrátí zvuk na reproduktor).
Future<void> stopTuner() => impl.stopTuner();

/// Referenční tón struny (Web Audio), mikrofon ho ignoruje.
Future<void> playTunerTone(double hz, {double seconds = 2.5}) => impl.playTunerTone(hz, seconds);

/// Chyba při spuštění ladičky -- `kind` pro českou hlášku v UI.
class TunerStartException implements Exception {
  const TunerStartException(this.kind, [this.detail]);

  /// 'denied' (zamítnutý přístup), 'unsupported', 'unavailable' (žádný mikrofon / obsazený), 'other'.
  final String kind;
  final String? detail;

  @override
  String toString() => 'TunerStartException($kind, $detail)';
}
