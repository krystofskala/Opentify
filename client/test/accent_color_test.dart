import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:opentify_client/theme/accent_color.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  group('normalizeAccent / isAchromatic', () {
    for (final color in [Colors.black, Colors.white, const Color(0xff808080)]) {
      test('neutrální $color zůstane neutrální a má použitelný kontrast', () {
        expect(isAchromatic(color), isTrue);
        final normalized = normalizeAccent(color);
        final hsl = HSLColor.fromColor(normalized);
        expect(hsl.saturation, 0);
        expect(hsl.lightness, inInclusiveRange(0.315, 0.625));
        // Po kvantizaci kanálů je povolena odchylka cca 1/255.
        // Pro text lze zvolit černou nebo bílou s WCAG AA kontrastem.
        expect(math.max(contrast(normalized, Colors.black),
            contrast(normalized, Colors.white)), greaterThanOrEqualTo(4.5));
      });
    }

    for (final hue in [0.0, 120.0, 240.0, 359.0]) {
      for (final lightness in [0.05, 0.32, 0.5, 0.62, 0.95]) {
        test('odstín $hue a světlost $lightness zachovají odstín', () {
          final input = HSLColor.fromAHSL(1, hue, 1, lightness).toColor();
          final normalized = normalizeAccent(input);
          final hsl = HSLColor.fromColor(normalized);
          expect(isAchromatic(input), isFalse);
          expect(hsl.lightness, closeTo(lightness.clamp(0.32, 0.62).toDouble(), 0.005));
          expect(hsl.saturation, closeTo(0.9, 0.015));
          final diff = ((hsl.hue - HSLColor.fromColor(input).hue + 540) % 360) - 180;
          expect(diff.abs(), lessThan(2));
        });
      }
    }

    test('barvy těsně pod a nad prahem achromatičnosti', () {
      // 8bit Color nelze obecně zkonstruovat s přesnou HSL sytostí 0.12.
      final below = HSLColor.fromAHSL(1, 120, 0.11, 0.5).toColor();
      final above = HSLColor.fromAHSL(1, 120, 0.13, 0.5).toColor();
      expect(isAchromatic(below), isTrue);
      expect(HSLColor.fromColor(normalizeAccent(below)).saturation, 0);
      expect(isAchromatic(above), isFalse);
      expect(HSLColor.fromColor(normalizeAccent(above)).saturation, greaterThan(0.12));
    });

    test('neutrální krajní barvy jsou omezeny na obě hranice světlosti', () {
      expect(HSLColor.fromColor(normalizeAccent(Colors.black)).lightness, closeTo(0.32, 0.005));
      expect(HSLColor.fromColor(normalizeAccent(Colors.white)).lightness, closeTo(0.62, 0.005));
    });
  });

  group('pickAccent ze syntetické palety bez obrázků a sítě', () {
    test('prázdná paleta nemá akcent', () {
      expect(pickAccent(PaletteGenerator.fromColors(<PaletteColor>[])), isNull);
    });

    test('jediná černá nebo bílá nezpůsobí červený akcent', () {
      for (final color in [Colors.black, Colors.white]) {
        final palette = PaletteGenerator.fromColors([PaletteColor(color, 100)]);
        expect(pickAccent(palette), normalizeAccent(color));
      }
    });

    test('jednobarevný obal zachová odstín a normalizuje sytost', () {
      final palette = PaletteGenerator.fromColors([PaletteColor(Colors.red, 100)]);
      expect(pickAccent(palette), normalizeAccent(Colors.red));
    });
  });

  test('cache pro chybějící nebo dosud neanalyzovanou URL je prázdná', () {
    expect(cachedAccentColor(null), isNull);
    expect(cachedAccentColor('unit-test://never-requested-cover'), isNull);
  });
}
