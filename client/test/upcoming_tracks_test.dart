import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/state/audio_player_controller.dart';

AudioPlayerState _state(
  List<String> ids,
  int index, {
  List<int>? shuffleOrder,
  RepeatMode repeat = RepeatMode.off,
}) {
  final queue = [for (final id in ids) NowPlayingInfo(recordingId: id, title: id)];
  return AudioPlayerState(
    nowPlaying: queue[index],
    isPlaying: true,
    isBuffering: false,
    position: Duration.zero,
    queue: queue,
    queueIndex: index,
    shuffleEnabled: shuffleOrder != null,
    shuffleOrder: shuffleOrder,
    repeatMode: repeat,
  );
}

void main() {
  test('další dvě skladby v pořadí fronty', () {
    expect(AudioPlayerController.upcomingRecordingIds(_state(['a', 'b', 'c', 'd'], 0), 2), ['b', 'c']);
  });

  test('konec fronty: jen co zbývá', () {
    expect(AudioPlayerController.upcomingRecordingIds(_state(['a', 'b', 'c'], 2), 2), isEmpty);
    expect(AudioPlayerController.upcomingRecordingIds(_state(['a', 'b', 'c'], 1), 2), ['c']);
  });

  test('zamíchané pořadí', () {
    final s = _state(['a', 'b', 'c', 'd'], 2, shuffleOrder: [2, 0, 3, 1]);
    expect(AudioPlayerController.upcomingRecordingIds(s, 2), ['a', 'd']);
  });

  test('opakování celé fronty jde přes začátek, bez právě hrající', () {
    final s = _state(['a', 'b'], 1, repeat: RepeatMode.all);
    expect(AudioPlayerController.upcomingRecordingIds(s, 2), ['a']);
  });
}
