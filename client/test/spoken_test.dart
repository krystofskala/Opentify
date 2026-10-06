import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/features/spoken/spoken_data.dart';
import 'package:opentify_client/state/audio_player_controller.dart';

void main() {
  test('položka knihy ve frontě se pozná a rozloží', () {
    expect(AudioPlayerController.isSpokenId('sp:b1:f2'), isTrue);
    expect(AudioPlayerController.isSpokenId('7f9c-recording'), isFalse);
    expect(AudioPlayerController.spokenParts('sp:b1:f2'), (bookId: 'b1', fileId: 'f2'));
    expect(AudioPlayerController.spokenParts('sp:jen-kniha'), isNull);
    expect(AudioPlayerController.spokenParts('abc'), isNull);
  });

  test('kniha ze serveru: stav, pozice, fronta souborů', () {
    final book = SpokenBook.fromJson({
      'id': 'b1',
      'title': 'Saturnin',
      'author': 'Zdeněk Jirotka',
      'narrator': 'Oldřich Vízner',
      'coverUrl': 'https://cdn.sktorrent.eu/obrazky/x.jpg',
      'releaseTitle': 'Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner',
      'status': 'ready',
      'progress': {'fileId': 'f2', 'positionMs': 61000, 'finished': false},
      'files': [
        {'id': 'f1', 'position': 0, 'title': '01', 'durationMs': 1000},
        {'id': 'f2', 'position': 1, 'title': '02', 'durationMs': 2000, 'chapters': [
          {'title': 'Kapitola 1', 'startMs': 0},
        ]},
      ],
    });
    expect(book.isReady, isTrue);
    expect(book.inProgress, isTrue);
    expect(book.byline, 'Zdeněk Jirotka · čte Oldřich Vízner');
    expect(book.files[1].chapters.single.title, 'Kapitola 1');
    final queue = spokenQueue(book);
    expect(queue.map((q) => q.recordingId), ['sp:b1:f1', 'sp:b1:f2']);
    expect(queue.first.artistName, 'Saturnin');
  });

  test('stahování: průběh z knihovny', () {
    final book = SpokenBook.fromJson({
      'id': 'b2', 'title': 'x', 'releaseTitle': 'x', 'status': 'downloading', 'progress': null, 'downloadProgress': 0.42,
    });
    expect(book.isWorking, isTrue);
    expect(book.downloadProgress, closeTo(0.42, 1e-9));
    expect(formatSize(500 * 1024 * 1024), '500 MB');
    expect(formatHours(2 * 3600000 + 5 * 60000), '2 h 5 min');
  });
}
