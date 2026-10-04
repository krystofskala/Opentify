// Náhledy pozadí (klasické vs. "Nové") pro obaly z disku -- jen pro ladění
// barev, běží jen s BG_PREVIEW_DIR (složka s c*.jpg, výstup do téže složky):
//   BG_PREVIEW_DIR=... flutter test test/background_preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/theme/accent_color.dart';
import 'package:opentify_client/widgets/app_background.dart';

void main() {
  final dir = Platform.environment['BG_PREVIEW_DIR'];

  testWidgets('background previews', (tester) async {
    if (dir == null) return;
    final covers = Directory(dir).listSync().whereType<File>().where((f) => RegExp(r'c\d+\.jpg$').hasMatch(f.path)).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    debugCoverProvider = (path) => MemoryImage(File(path).readAsBytesSync());
    await tester.binding.setSurfaceSize(const Size(360, 640));

    for (final cover in covers) {
      final analysis = await tester.runAsync(() async => (
            accent: await extractAccentColor(cover.path),
            support: await extractSupportTones(cover.path),
            character: await extractCoverCharacter(cover.path),
          ));
      final ch = analysis!.character;
      // ignore: avoid_print
      print('${cover.path.split(Platform.pathSeparator).last}: hues=${ch?.hues.map((g) => '${g.color.toARGB32().toRadixString(16)}@${g.share.toStringAsFixed(2)}').join(',')} guests=${ch?.guests.map((g) => '${g.color.toARGB32().toRadixString(16)}@${g.share.toStringAsFixed(2)}').join(',')} '
          'black=${ch?.black.toStringAsFixed(2)} white=${ch?.white.toStringAsFixed(2)}');
      for (final brightness in Brightness.values) {
        for (final v2 in [false, true]) {
          final key = GlobalKey();
          await tester.pumpWidget(MediaQuery(
            data: const MediaQueryData(size: Size(360, 640)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: RepaintBoundary(
                key: key,
                child: AppBackground(
                  selectedAccent: analysis.accent,
                  supportTones: analysis.support,
                  character: ch,
                  brightness: brightness,
                  isPlaying: false,
                  hidden: false,
                  noGrain: true,
                  v2: v2,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ));
          await tester.pump(const Duration(milliseconds: 100));
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final bytes = await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            return data!.buffer.asUint8List();
          });
          final name = cover.path.replaceAll(RegExp(r'\.jpg$'), '_${brightness.name}_${v2 ? 'v2' : 'classic'}.png');
          File(name).writeAsBytesSync(bytes!);
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
