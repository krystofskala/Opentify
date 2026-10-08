import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/spoken_collections.dart';
import 'package:opentify_client/features/spoken/spoken_data.dart';
import 'package:opentify_client/theme/app_theme.dart';

void main() {
  testWidgets('Sbírka knih: knihy v pořadí, odebrat', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SpokenBook book(String id, String title) =>
        SpokenBook.fromJson({'id': id, 'title': title, 'author': 'Andrzej Sapkowski', 'releaseTitle': 'x', 'status': 'ready'});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        spokenCollectionsProvider.overrideWith((ref) async => <SpokenCollection>[
              (id: 'c', title: 'Na dovolenou', bookIds: ['b2', 'b1'], coverUrl: null),
            ]),
        spokenBooksProvider.overrideWith((ref) async => [book('b1', 'Krev elfů'), book('b2', 'Meč osudu')]),
      ],
      child: MaterialApp(
        theme: buildAppTheme(seed: Colors.deepPurple, brightness: Brightness.dark),
        home: const SpokenCollectionScreen(collectionId: 'c'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Na dovolenou'), findsOneWidget);
    final first = tester.getTopLeft(find.text('Meč osudu')).dy;
    final second = tester.getTopLeft(find.text('Krev elfů')).dy;
    expect(first < second, isTrue);
    expect(find.byTooltip('Odebrat ze sbírky'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
