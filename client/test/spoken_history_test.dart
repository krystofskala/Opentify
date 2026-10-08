import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/spoken_history_screen.dart';
import 'package:opentify_client/theme/app_theme.dart';

void main() {
  testWidgets('Historie mluveného slova: dny, čas poslechu', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1200 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        spokenHistoryProvider.overrideWith((ref) async => <SpokenHistoryDay>[
              (
                day: DateTime(now.year, now.month, now.day),
                items: <SpokenHistoryItem>[
                  (kind: 'book', ref: 'b', title: 'Krev elfů', subtitle: 'Andrzej Sapkowski', coverUrl: null, showId: null, seconds: 5400, gone: false),
                  (kind: 'episode', ref: 'e', title: 'Díl 12', subtitle: 'Vinohradská 12', coverUrl: null, showId: 's', seconds: 900, gone: false),
                ],
              ),
            ]),
      ],
      child: MaterialApp(
        theme: buildAppTheme(seed: Colors.deepPurple, brightness: Brightness.dark),
        home: const SpokenHistoryScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Dnes'), findsOneWidget);
    expect(find.text('1 h 45 min'), findsOneWidget);
    expect(find.text('Andrzej Sapkowski · 1 h 30 min'), findsOneWidget);
    expect(find.text('Vinohradská 12 · 15 min'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
