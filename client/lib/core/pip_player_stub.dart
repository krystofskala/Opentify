import 'pip_player.dart';

PipPlayer createPipPlayer() => _NoPip();

class _NoPip implements PipPlayer {
  @override
  bool get supported => false;
  @override
  bool get isOpen => false;
  @override
  void setHandlers({
    required void Function() onPlayPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function() onLike,
    void Function()? onOpened,
  }) {}
  @override
  void setAutoOpen(bool on) {}
  @override
  Future<void> open() async {}
  @override
  void close() {}
  @override
  void update(PipState state) {}
}
