import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/widgets/wavy_seek_bar.dart';

void main() {
  testWidgets('při tažení lišty bublina s časem, po puštění zmizí', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          // Jako mini přehrávač: sklo s ořezem -- bublina nesmí být uvnitř.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: 300,
              child: WavySeekBar(progress: 0.1, onChangeEnd: (_) {}, dragLabel: (v) => 'T ${(v * 100).round()}'),
            ),
          ),
        ),
      ),
    ));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(WavySeekBar)));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(find.textContaining('T '), findsOneWidget);
    // Vykresluje se v Overlay (render strom), ne pod ořezem.
    RenderObject? r = tester.renderObject(find.textContaining('T '));
    while (r != null) {
      expect(r, isNot(isA<RenderClipRRect>()));
      r = r.parent;
    }
    expect(tester.getRect(find.textContaining('T ')).bottom, lessThanOrEqualTo(tester.getRect(find.byType(WavySeekBar)).top));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('T '), findsNothing);
  });
}
