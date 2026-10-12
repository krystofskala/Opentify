import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/widgets/wavy_seek_bar.dart';

Widget _host(Widget bar, {VoidCallback? onParentTap}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: GestureDetector(
            onTap: onParentTap,
            child: SizedBox(width: 300, child: bar),
          ),
        ),
      ),
    );

void main() {
  testWidgets('ťuknutí přetočí: onChanged i onChangeEnd s polohou prstu', (tester) async {
    final changed = <double>[];
    final ended = <double>[];
    await tester.pumpWidget(_host(WavySeekBar(progress: 0.1, isPlaying: true, onChanged: changed.add, onChangeEnd: ended.add)));
    final rect = tester.getRect(find.byType(WavySeekBar));
    await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));
    await tester.pump();
    expect(ended.single, closeTo(0.75, 0.02));
    expect(changed.single, ended.single);
  });

  testWidgets('tažení hlásí průběžně a na konci jednou', (tester) async {
    final changed = <double>[];
    final ended = <double>[];
    await tester.pumpWidget(_host(WavySeekBar(progress: 0.2, isPlaying: true, onChanged: changed.add, onChangeEnd: ended.add)));
    final rect = tester.getRect(find.byType(WavySeekBar));
    final g = await tester.startGesture(Offset(rect.left + rect.width * 0.2, rect.center.dy));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(changed.length, greaterThan(1));
    expect(ended.length, 1);
    expect(ended.single, greaterThan(0.4));
  });

  testWidgets('interactive: false nekrade klepnutí rodiči', (tester) async {
    var parentTaps = 0;
    final ended = <double>[];
    await tester.pumpWidget(_host(
      WavySeekBar(progress: 0.5, isPlaying: true, interactive: false, onChangeEnd: ended.add),
      onParentTap: () => parentTaps++,
    ));
    await tester.tap(find.byType(WavySeekBar));
    await tester.pump();
    expect(parentTaps, 1);
    expect(ended, isEmpty);
  });

  testWidgets('tapToSeek: false -- klepnutí patří rodiči, tažení přetáčí', (tester) async {
    var parentTaps = 0;
    final ended = <double>[];
    await tester.pumpWidget(_host(
      WavySeekBar(progress: 0.5, isPlaying: true, tapToSeek: false, onChangeEnd: ended.add),
      onParentTap: () => parentTaps++,
    ));
    await tester.tap(find.byType(WavySeekBar));
    await tester.pump();
    expect(parentTaps, 1);
    expect(ended, isEmpty);
    await tester.drag(find.byType(WavySeekBar), const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(ended.length, 1);
  });

  testWidgets('v pauze se nic neanimuje (žádné čekající snímky)', (tester) async {
    await tester.pumpWidget(_host(const WavySeekBar(progress: 0.5, isPlaying: false)));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
