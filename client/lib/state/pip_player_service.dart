import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/pip_player.dart';
import 'artwork_provider.dart';
import 'audio_player_controller.dart';
import 'liked_songs_controller.dart';

/// Otevřít plovoucí přehrávač samo při přepnutí panelu (výchozí ano, jako
/// Spotify); vypíná se v Profilu › Vzhled. Jen pro toto zařízení.
final pipAutoOpenProvider = StateNotifierProvider<PipAutoOpen, bool>((ref) => PipAutoOpen());

class PipAutoOpen extends StateNotifier<bool> {
  PipAutoOpen() : super(true) {
    unawaited(SharedPreferences.getInstance().then((p) {
      if (mounted) state = p.getBool(_key) ?? true;
    }).catchError((Object _) {}));
  }

  static const _key = 'pip_auto_open';

  Future<void> set(bool on) async {
    state = on;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, on);
    } catch (_) {}
  }
}

/// Plovoucí mini přehrávač na webu (viz `PipPlayer`): drží okno v souladu
/// s přehrávačem. Čte se jednou v `OpentifyApp` -- pak se okno může otevřít
/// i samo při přepnutí panelu.
final pipPlayerProvider = Provider<PipPlayer>((ref) {
  final pip = PipPlayer();
  if (!pip.supported) return pip;
  final player = ref.read(audioPlayerControllerProvider.notifier);
  String? art;
  String? artFor;

  void push() {
    final s = ref.read(audioPlayerControllerProvider);
    final info = s.nowPlaying;
    if (info == null) return;
    final spoken = AudioPlayerController.isSpokenId(info.recordingId);
    final ms = s.shownDuration?.inMilliseconds ?? 0;
    if (artFor != info.recordingId) {
      artFor = info.recordingId;
      art = info.artworkUrl;
      // Skladby z fronty obal často nenesou -- dohledat jako zamčená obrazovka.
      if (art == null && (info.releaseId != null || info.artistId != null)) {
        final requested = info.recordingId;
        final provider = recordingArtworkProvider((releaseId: info.releaseId, artistId: info.artistId));
        final keep = ref.listen<AsyncValue<String?>>(provider, (_, __) {});
        unawaited(ref.read(provider.future).then((url) {
          if (url != null && artFor == requested) {
            art = url;
            push();
          }
        }).catchError((Object _) {}).whenComplete(keep.close));
      }
    }
    pip.update((
      title: info.title,
      artist: info.artistName,
      artworkUrl: art ?? info.artworkUrl,
      playing: s.isPlaying,
      liked: ref.read(likedSongsControllerProvider).valueOrNull?.contains(info.recordingId) ?? false,
      spoken: spoken,
      progress: ms <= 0 ? 0 : s.position.inMilliseconds / ms,
    ));
  }

  pip.setHandlers(
    onPlayPause: () => unawaited(player.togglePlayPause()),
    onNext: () {
      final id = ref.read(audioPlayerControllerProvider).nowPlaying?.recordingId;
      unawaited(id != null && AudioPlayerController.isSpokenId(id) ? player.seekBy(const Duration(seconds: 30)) : player.next());
    },
    onPrevious: () {
      final id = ref.read(audioPlayerControllerProvider).nowPlaying?.recordingId;
      unawaited(id != null && AudioPlayerController.isSpokenId(id) ? player.seekBy(const Duration(seconds: -30)) : player.previous());
    },
    onLike: () {
      final id = ref.read(audioPlayerControllerProvider).nowPlaying?.recordingId;
      if (id == null || AudioPlayerController.isSpokenId(id)) return;
      final liked = ref.read(likedSongsControllerProvider).valueOrNull?.contains(id) ?? false;
      unawaited(ref.read(likedSongsControllerProvider.notifier).setLiked(id, !liked));
    },
    onOpened: push,
  );
  ref.listen(pipAutoOpenProvider, (_, on) => pip.setAutoOpen(on), fireImmediately: true);

  // Pozice tiká často -- do okna nejvýš jednou za sekundu, jiné změny hned.
  DateTime last = DateTime.fromMillisecondsSinceEpoch(0);
  ref.listen(audioPlayerControllerProvider, (prev, next) {
    if (!pip.isOpen) return;
    final onlyTick = prev != null &&
        prev.nowPlaying?.recordingId == next.nowPlaying?.recordingId &&
        prev.isPlaying == next.isPlaying &&
        prev.nowPlaying?.artworkUrl == next.nowPlaying?.artworkUrl;
    final now = DateTime.now();
    if (onlyTick && now.difference(last) < const Duration(seconds: 1)) return;
    last = now;
    push();
  });
  ref.listen(likedSongsControllerProvider, (_, __) {
    if (pip.isOpen) push();
  });
  ref.onDispose(pip.close);
  return pip;
});
