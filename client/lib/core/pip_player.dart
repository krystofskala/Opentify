import 'pip_player_stub.dart' if (dart.library.js_interop) 'pip_player_web.dart' as impl;

/// Stav pro plovoucí okno.
typedef PipState = ({
  String title,
  String? artist,
  String? artworkUrl,
  bool playing,
  bool liked,
  bool spoken,
  double progress,
});

/// Plovoucí mini přehrávač na webu (Chrome / Edge, Document Picture-in-Picture):
/// malé okno nad ostatními okny -- obal, název, ⏮ ⏯ ⏭, srdíčko. Otevře se
/// ručně z menu přehrávače, nebo samo při přepnutí panelu, když to prohlížeč
/// dovolí (Michael, 8. 10. -- jako open.spotify.com). Jinde (nativní appka,
/// Firefox, Safari) `supported` = false a nic nedělá.
abstract class PipPlayer {
  factory PipPlayer() => impl.createPipPlayer();

  bool get supported;
  bool get isOpen;

  void setHandlers({
    required void Function() onPlayPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function() onLike,
    void Function()? onOpened,
  });

  /// Prohlížeč ho smí otevřít sám při přepnutí panelu (Media Session
  /// `enterpictureinpicture`, Chrome 134+); jinde se nic nestane.
  void enableAutoOpen();

  Future<void> open();
  void close();
  void update(PipState state);
}
