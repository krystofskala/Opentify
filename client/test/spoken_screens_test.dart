import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/podcast_data.dart';
import 'package:opentify_client/features/spoken/spoken_data.dart';
import 'package:opentify_client/features/spoken/spoken_screens.dart';
import 'package:opentify_client/theme/app_theme.dart';

SpokenBook _book(String id, String status, {Map<String, dynamic>? progress, double dl = 0}) => SpokenBook.fromJson({
      'id': id,
      'title': 'Saturnin – velmi dlouhý název knihy, který se nevejde na jeden řádek',
      'author': 'Zdeněk Jirotka',
      'narrator': 'Oldřich Vízner',
      'releaseTitle': 'Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner',
      'status': status,
      'progress': progress,
      'downloadProgress': dl,
      'durationMs': 9 * 3600000,
    });

Widget _app(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildAppTheme(seed: Colors.deepPurple, brightness: Brightness.dark),
        home: child,
      ),
    );

void main() {
  testWidgets('Domů mluveného slova: pokračovat, nové díly, polička, stahuje se', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SpokenHomeScreen(), [
      spokenBooksProvider.overrideWith((ref) async => [
            _book('a', 'ready', progress: {'fileId': 'f', 'positionMs': 1000, 'finished': false}),
            _book('b', 'downloading', dl: 0.4),
            _book('c', 'pending'),
            _book('d', 'ready'),
          ]),
      myPodcastsProvider.overrideWith((ref) async => [PodcastShowItem.fromJson({'id': 's1', 'title': 'Vinohradská 12', 'subscribed': true})]),
      podcastHomeProvider.overrideWith((ref) async => (
            inProgress: <PodcastEpisodeItem>[],
            latest: [PodcastEpisodeItem.fromJson({'id': 'e1', 'title': 'Díl', 'showTitle': 'V12', 'durationMs': 60000})],
          )),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Pokračovat'), findsOneWidget);
    expect(find.text('Tvoje pořady'), findsOneWidget);
    expect(find.text('Nové díly'), findsOneWidget);
    expect(find.text('Tvoje knihy'), findsOneWidget);
    expect(find.text('Stahuje se'), findsOneWidget);
    expect(find.text('Stahuje se · 40 %'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Hledání audioknih: výsledky se Stáhnout bez přetečení', (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SpokenSearchScreen(), [
      spokenSearchProvider.overrideWith((ref, q) async => (
            releases: [
              const SpokenRelease(
                infohash: '2dce9ad02753466981d1c8ae819a95618c5e652d',
                title: 'Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner a ještě něco navíc dlouhého',
                sizeBytes: 524707430,
                seeders: 8,
              ),
              const SpokenRelease(
                infohash: '72a5c49b90f75ce1fac16180ce6359f0476f6714',
                title: 'Jirotka - Saturnin',
                seeders: 0,
                bookId: 'b',
                status: 'downloading',
              ),
            ],
            loginConfigured: false,
          )),
    ]));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'saturnin');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Stáhnout'), findsOneWidget);
    expect(find.text('Stahuje se'), findsOneWidget);
    expect(find.textContaining('účet SkTorrent'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  collectionSheetTests();
}

void collectionSheetTests() {
  testWidgets('sbírka: výběr knihy přepočítá velikost a celá kniha zaškrtne části', (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 812 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const mb = 1024 * 1024;
    final groups = <ReleaseGroup>[
      (folder: 'kniha 1.poslední přání', size: 700 * mb, files: [(index: 0, name: '01.mp3', size: 350 * mb), (index: 1, name: '02.mp3', size: 350 * mb)]),
      (folder: 'kniha 2.meč osudu', size: 800 * mb, files: [(index: 2, name: '01.mp3', size: 800 * mb)]),
    ];
    await tester.pumpWidget(_app(
      const Scaffold(
        body: CollectionPickSheet(
          release: SpokenRelease(infohash: 'a', title: 'Zaklínač komplet', seeders: 30),
          groups: [],
        ),
      ),
      const [],
    ));
    await tester.pumpWidget(_app(
      Scaffold(
        body: CollectionPickSheet(
          release: const SpokenRelease(infohash: 'a', title: 'Zaklínač komplet', seeders: 30),
          groups: groups,
        ),
      ),
      const [],
    ));
    await tester.pump();
    expect(find.text('Vyber, co stáhnout'), findsOneWidget);
    await tester.tap(find.text('kniha 1.poslední přání'));
    await tester.pump();
    expect(find.text('Stáhnout vybrané (700 MB)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
