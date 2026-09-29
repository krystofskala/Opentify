import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/tuner/tuner_logic.dart';

/// Pošle `count` odhadů po ~21 ms (jako detektor) a vrátí poslední výstup.
TunerOutput feed(TunerFilter f, double hz, int count, {required List<Duration> clock, double rms = 0.05}) {
  late TunerOutput out;
  for (var i = 0; i < count; i++) {
    clock[0] += const Duration(milliseconds: 21);
    out = f.add(hz, 0.95, rms, clock[0]);
  }
  return out;
}

double cents(double hz, double c) => hz * math.pow(2, c / 1200);

void main() {
  test('české názvy tónů a ladění', () {
    expect(tuningById('standard').label, 'E A D G H E');
    expect(tuningById('half-down').label, 'E♭ A♭ D♭ G♭ B E♭');
    expect(tuningById('drop-d').label, 'D A D G H E');
    expect(noteName(70), 'B'); // anglické B♭
    expect(noteOctave(40), 2);
    expect(midiToHz(69), closeTo(440, 1e-9));
    expect(hzToMidi(82.4069), closeTo(40, 1e-3));
    expect(hzToMidi(432, a4: 432), closeTo(69, 1e-9));
  });

  test('rozpozná strunu, odchylku a naladění', () {
    final clock = [Duration.zero];
    final f = TunerFilter(tuning: tuningById('standard'));
    // Silence first, so the noise floor is low.
    for (var i = 0; i < 20; i++) {
      clock[0] += const Duration(milliseconds: 21);
      f.add(0, 0, 0.0005, clock[0]);
    }
    var out = feed(f, cents(110, 12), 30, clock: clock);
    expect(out.active, isTrue);
    expect(out.stringIndex, 1); // A
    expect(out.cents, closeTo(12, 0.5));
    expect(out.inTune, isFalse);

    out = feed(f, cents(110, 1), 30, clock: clock);
    expect(out.cents, closeTo(1, 0.5));
    expect(out.inTune, isTrue);
    expect(f.tuned, contains(1));
  });

  test('ojedinělý oktávový skok nezmění strunu ani ručičku', () {
    final clock = [Duration.zero];
    final f = TunerFilter(tuning: tuningById('standard'));
    feed(f, 82.41, 30, clock: clock);
    final out = feed(f, 164.82, 1, clock: clock);
    expect(out.stringIndex, 0);
    expect(out.cents.abs(), lessThan(1));
  });

  test('ruční struna sklopí harmonickou k cíli', () {
    final clock = [Duration.zero];
    final f = TunerFilter(tuning: tuningById('standard'), targetString: 0);
    final out = feed(f, cents(82.41 * 2, -8), 30, clock: clock);
    expect(out.stringIndex, 0);
    expect(out.midi, 40);
    expect(out.cents, closeTo(-8, 0.6));
  });

  test('tón daleko od strun -> chromaticky, ticho -> po chvíli neaktivní', () {
    final clock = [Duration.zero];
    final f = TunerFilter(tuning: tuningById('standard'));
    final far = feed(f, 523.25, 20, clock: clock); // C5
    expect(far.stringIndex, isNull);
    expect(far.midi, 72);

    TunerOutput out = far;
    for (var i = 0; i < 80; i++) {
      clock[0] += const Duration(milliseconds: 21);
      out = f.add(0, 0, 0.0005, clock[0]);
    }
    expect(out.active, isFalse);
  });

  test('dlouhý doznívající tón se neuřízne', () {
    final clock = [Duration.zero];
    final f = TunerFilter(tuning: tuningById('standard'));
    TunerOutput out = TunerOutput.idle;
    for (var i = 0; i < 240; i++) {
      clock[0] += const Duration(milliseconds: 21);
      out = f.add(196, 0.95, 0.06 * math.exp(-i / 110), clock[0]); // ~5 s, zeslábne na ~1/9
    }
    expect(out.active, isTrue);
    expect(out.stringIndex, 3);
  });

  test('kalibrace A4 posune cíl', () {
    final clock = [Duration.zero];
    final f = TunerFilter(tuning: tuningById('standard'), a4: 432);
    final out = feed(f, midiToHz(45, a4: 432), 20, clock: clock);
    expect(out.stringIndex, 1);
    expect(out.cents.abs(), lessThan(0.5));
  });
}
