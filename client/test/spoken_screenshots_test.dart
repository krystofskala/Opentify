// Screenshoty obrazovek mluveného slova s ukázkovými daty -- jen pro
// ukázku, běží jen s SCREEN_DIR (výstup PNG do té složky):
//   SCREEN_DIR=... flutter test test/spoken_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/podcast_data.dart';
import 'package:opentify_client/features/spoken/spoken_data.dart';
import 'package:opentify_client/features/spoken/spoken_screens.dart';
import 'package:opentify_client/theme/app_theme.dart';

SpokenBook _book(String id, String title, String author, {bool mine = true, Map<String, dynamic>? progress}) =>
    SpokenBook.fromJson({
      'id': id,
      'title': title,
      'author': author,
      'narrator': 'Oldřich Vízner',
      'releaseTitle': title,
      'status': 'ready',
      'progress': progress,
      'durationMs': 7 * 3600000 + 1200000,
      'mine': mine,
    });

Future<void> _font(String family, String path) async {
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

void main() {
  final dir = Platform.environment['SCREEN_DIR'];

  Future<void> shoot(WidgetTester tester, String name, Widget screen, List<Override> overrides) async {
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(seed: const Color(0xFF7B2CFF), brightness: Brightness.dark),
          home: ColoredBox(color: const Color(0xFF14121C), child: screen),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    File('$dir/$name.png').writeAsBytesSync(bytes!);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('spoken screenshots', (tester) async {
    if (dir == null) return;
    final home = Platform.environment['LOCALAPPDATA']!;
    await tester.runAsync(() async {
      await _font('Nunito', 'assets/fonts/Nunito/Nunito-VariableFont_wght.ttf');
      await _font(
        'packages/material_symbols_icons/MaterialSymbolsRounded',
        '$home/Pub/Cache/hosted/pub.dev/material_symbols_icons-4.2960.0/lib/fonts/MaterialSymbolsRounded.ttf',
      );
    });
    tester.view.physicalSize = const Size(390 * 2, 2500 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final books = [
      _book('a', 'Saturnin', 'Zdeněk Jirotka', progress: {'fileId': 'f', 'positionMs': 1000, 'finished': false}),
      _book('b', 'Muž se psem', 'Zdeněk Jirotka'),
      _book('c', 'Krakatit', 'Karel Čapek', mine: false),
      _book('d', 'Válka s mloky', 'Karel Čapek', mine: false),
      _book('e', 'Bylo nás pět', 'Karel Poláček', mine: false),
    ];
    await shoot(tester, '1_domu_mluvene_slovo', const SpokenHomeScreen(), [
      spokenBooksProvider.overrideWith((ref) async => books),
      spokenRecommendationsProvider.overrideWith((ref) async => (
            podcasts: [(show: const PodcastSearchResult(title: 'Buchty', feedUrl: 'https://x/rss'), reason: 'Poslouchal jsi na Spotify')],
            books: [(release: const SpokenRelease(infohash: 'r', title: 'Sága o impériu', seeders: 80), reason: 'Populární teď')],
          )),
      myPodcastsProvider.overrideWith((ref) async => [PodcastShowItem.fromJson({'id': 's1', 'title': 'Vinohradská 12', 'subscribed': true})]),
      podcastHomeProvider.overrideWith((ref) async => (
            inProgress: <PodcastEpisodeItem>[],
            latest: [PodcastEpisodeItem.fromJson({'id': 'e1', 'title': 'Proč zdražují byty', 'showTitle': 'Vinohradská 12', 'durationMs': 1800000})],
          )),
      spokenHomeLayoutProvider.overrideWith((ref) async => null),
    ]);
    await shoot(tester, '2_stranka_autora', const SpokenPersonScreen(name: 'Zdeněk Jirotka'), [
      spokenPersonProvider.overrideWith((ref, who) async => (
            name: who.name,
            role: who.role,
            books: [books[0], books[1]],
            releases: const [
              SpokenRelease(infohash: 'h1', title: 'Profesor Kujal spí - Zdeněk Jirotka (2015) čte Jiří Lábus', sizeBytes: 312000000, seeders: 6),
              SpokenRelease(infohash: 'h2', title: 'Pravidla mravného chování - Zdeněk Jirotka', sizeBytes: 98000000, seeders: 2),
              SpokenRelease(infohash: 'h3', title: 'Hvězda padá vzhůru - Zdeněk Jirotka (2019)', sizeBytes: 401000000, seeders: 0),
            ],
            loginConfigured: true,
          )),
    ]);
  });
}
