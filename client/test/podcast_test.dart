import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/podcast_data.dart';
import 'package:opentify_client/features/spoken/podcast_screens.dart';
import 'package:opentify_client/state/audio_player_controller.dart';
import 'package:opentify_client/theme/app_theme.dart';

final _show = PodcastShowItem.fromJson({
  'id': 's1',
  'title': 'Vinohradská 12',
  'author': 'Český rozhlas',
  'subscribed': false,
  'description': 'Zpravodajský podcast Českého rozhlasu.',
  'episodes': [
    {'id': 'e2', 'title': 'Nejnovější díl s hodně dlouhým názvem, který se nevejde na jeden řádek', 'showTitle': 'Vinohradská 12',
     'publishedAt': '2026-10-06T00:01:00+02:00', 'durationMs': 1466000, 'positionMs': 0, 'finished': false},
    {'id': 'e1', 'title': 'Rozposlouchaný díl', 'showTitle': 'Vinohradská 12',
     'publishedAt': '2026-10-05T00:01:00+02:00', 'durationMs': 1466000, 'positionMs': 600000, 'finished': false},
    {'id': 'e0', 'title': 'Přehraný díl', 'showTitle': 'Vinohradská 12',
     'publishedAt': '2025-12-24T00:01:00+01:00', 'durationMs': 1000000, 'positionMs': 0, 'finished': true},
  ],
});

void main() {
  test('epizoda ve frontě je mluvené slovo', () {
    expect(AudioPlayerController.isSpokenId('pc:e1'), isTrue);
    expect(AudioPlayerController.podcastEpisodeId('pc:e1'), 'e1');
    expect(AudioPlayerController.podcastEpisodeId('sp:b:f'), isNull);
    expect(AudioPlayerController.spokenParts('pc:e1'), isNull);
    final item = _show.episodes[1].toQueueItem();
    expect(item.recordingId, 'pc:e1');
    expect(item.artistName, 'Vinohradská 12');
    expect(_show.episodes[1].started, isTrue);
    expect(_show.episodes[2].started, isFalse);
  });

  test('datum epizody', () {
    final now = DateTime(2026, 10, 6, 8);
    expect(episodeDate(DateTime(2026, 10, 6, 0, 1), now), 'Dnes');
    expect(episodeDate(DateTime(2026, 10, 5, 0, 1), now), 'Včera');
    expect(episodeDate(DateTime(2026, 9, 1), now), '1. zář');
    expect(episodeDate(DateTime(2025, 12, 24), now), '24. pro 2025');
  });

  testWidgets('Poslouchal jsi na Spotify: odebírat / odebíráš / jen na Spotify / hledá se', (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 812 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    PodcastHistoryItem item(String name, {bool pending = false, bool found = true, bool subscribed = false}) =>
        PodcastHistoryItem.fromJson({
          'name': name, 'title': name, 'listenedMs': 68 * 3600000, 'episodes': 109,
          'lastPlayedAt': '2025-11-01T10:00:00Z', 'pending': pending, 'found': found,
          'feedUrl': found ? 'https://example.org/$name' : null, 'showId': subscribed ? 's1' : null,
          'subscribed': subscribed,
        });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        podcastHistoryProvider.overrideWith((ref) async => [
              item('Buchty'),
              item('Vinohradská 12', subscribed: true),
              item('Exkluzivní pořad', found: false),
              item('Ešus', pending: true),
            ]),
      ],
      child: MaterialApp(
        theme: buildAppTheme(seed: Colors.teal, brightness: Brightness.dark),
        home: const PodcastHistoryScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Odebírat'), findsOneWidget);
    expect(find.text('Odebíráš'), findsOneWidget);
    expect(find.textContaining('jen na Spotify'), findsOneWidget);
    expect(find.textContaining('dohledávám 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('obrazovka pořadu se vykreslí bez chyb', (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 812 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [podcastShowProvider.overrideWith((ref, id) async => _show)],
      child: MaterialApp(
        theme: buildAppTheme(seed: Colors.teal, brightness: Brightness.dark),
        home: const PodcastShowScreen(showId: 's1'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Odebírat'), findsOneWidget);
    expect(find.textContaining('přehráno'), findsOneWidget);
    expect(find.textContaining('zbývá'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
