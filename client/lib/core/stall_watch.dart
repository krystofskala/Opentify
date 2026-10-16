/// Hlídač záseku startu (obecná chyba přehrávače, Kryštof 16. 10.: "někdy se
/// to nepouští, musím pustit další a vrátit se"): po play() / startu do 5 s
/// nepřibyla pozice nebo zdroj visí v načítání -> znovu načíst, nejvýš 2×.
class StallWatch {
  StallWatch({this.limitMs = 5000, this.maxReloads = 2});
  final double limitMs;
  final int maxReloads;

  double? _since;
  double? _startPos;
  int reloads = 0;

  /// Hlídání startu (play() nebo načtení zdroje, který má hrát).
  void arm(double nowMs, double positionMs) {
    _since = nowMs;
    _startPos = positionMs;
  }

  void disarm() => _since = null;

  /// Nová skladba: počítadlo znovunačtení od nuly.
  void newTrack() {
    reloads = 0;
    _since = null;
  }

  bool get armed => _since != null;

  /// `reload` = znovu načíst zdroj, `fail` = vzdát (hlásit chybu), jinak nic.
  String check({required double nowMs, required double positionMs, required bool wantsPlaying}) {
    final since = _since;
    if (since == null || !wantsPlaying) return 'ok';
    if (positionMs > (_startPos ?? 0) + 200) {
      _since = null; // rozjelo se
      return 'ok';
    }
    if (nowMs - since < limitMs) return 'ok';
    _since = null;
    if (reloads >= maxReloads) return 'fail';
    reloads++;
    return 'reload';
  }
}
