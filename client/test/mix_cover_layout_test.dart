// Obaly mixů v2 -- dvě chyby z iPhonu 18. 10. (Okoun, screeny IMG_6803/6810):
// název široké dlaždice se lámal uprostřed slova a vlny denního mixu v hlavičce
// detailu končily před pravým okrajem.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/widgets/mix_artwork.dart';
import 'package:opentify_client/widgets/mix_cover.dart';

void main() {
  // Skutečné Archivo (v testech je jinak Ahem, kde má každý znak šířku 1 em).
  setUpAll(() async {
    final loader = FontLoader('Archivo')
      ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Archivo/Archivo-Variable.ttf').readAsBytesSync())));
    await loader.load();
  });

  testWidgets('nejdelší slovo názvu dlaždice se vejde na řádek', (tester) async {
    const spec = MixArtSpec(style: MixArtStyle.mood, seed: 'home:mix:my-top', headline: 'Moje nejposlouchanější');
    await tester.pumpWidget(MaterialApp(
      home: Center(child: SizedBox(width: 175, height: 56, child: mixCoverWideV2(spec, 'Moje nejposlouchanější'))),
    ));
    final text = tester.widget<Text>(find.text('Moje nejposlouchanější'));
    // Místo pro název: dlaždice bez okraje vlevo (h * 0,22) a motivu vpravo (h * 1,39).
    const volno = 175 - 56 * 0.22 - 56 * 1.39;
    final painter = TextPainter(
      text: TextSpan(text: 'nejposlouchanější', style: text.style),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(painter.width, lessThanOrEqualTo(volno + 0.5));
  });

  testWidgets('vlny denního mixu sahají až k pravému okraji široké hlavičky', (tester) async {
    const spec = MixArtSpec(style: MixArtStyle.daily, seed: 'personal:daily-mix:1', headline: '1');
    await tester.pumpWidget(MaterialApp(
      home: Align(alignment: Alignment.topLeft, child: RepaintBoundary(
        key: const Key('obal'),
        child: SizedBox(width: 400, height: 300, child: mixCoverV2(spec)),
      )),
    ));
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('obal')));
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(() => image!.toByteData());
    // Pixel u pravého okraje dole má být barva vlny, ne podklad (bg) obalu.
    Color at(int x, int y) {
      final i = (y * image!.width + x) * 4;
      return Color.fromARGB(data!.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
    }
    final vpravoDole = at(image!.width - 3, image.height - 20);
    final vlevoDole = at(3, image.height - 20);
    expect(vpravoDole, vlevoDole);
  });
}
