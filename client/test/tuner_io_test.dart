import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/tuner/tuner_bridge_io.dart';

void main() {
  for (final hz in [82.41, 110.0, 196.0, 329.63]) {
    test('pozná $hz Hz', () {
      const sr = 48000.0;
      final s = Float64List(48000);
      for (var i = 0; i < s.length; i++) {
        s[i] = 0.5 * math.sin(2 * math.pi * hz * i / sr) + 0.2 * math.sin(4 * math.pi * hz * i / sr);
      }
      final r = detectPitchForTest(s, sr).last;
      expect(r.$1, closeTo(hz, hz * 0.003));
      expect(r.$2, greaterThan(0.9));
    });
  }
}
