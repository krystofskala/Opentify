import 'dart:math' as math;

/// Ladění kytary jako MIDI čísla strun od nejhlubší (6. struna) po nejvyšší.
class GuitarTuning {
  const GuitarTuning(this.id, this.name, this.midi, {this.flats = false});

  final String id;
  final String name;
  final List<int> midi;

  /// Snížené ladění se píše s béčky (E♭ A♭ D♭…), ne s křížky.
  final bool flats;

  String get label => midi.map((m) => noteName(m, flats: flats)).join(' ');
}

const guitarTunings = <GuitarTuning>[
  GuitarTuning('standard', 'Standardní', [40, 45, 50, 55, 59, 64]),
  GuitarTuning('drop-d', 'Drop D', [38, 45, 50, 55, 59, 64]),
  GuitarTuning('half-down', 'O půl tónu níž', [39, 44, 49, 54, 58, 63], flats: true),
  GuitarTuning('full-down', 'O celý tón níž', [38, 43, 48, 53, 57, 62]),
  GuitarTuning('drop-c', 'Drop C', [36, 43, 48, 53, 57, 62]),
  GuitarTuning('dadgad', 'DADGAD', [38, 45, 50, 55, 57, 62]),
  GuitarTuning('open-g', 'Open G', [38, 43, 50, 55, 59, 62]),
  GuitarTuning('open-d', 'Open D', [38, 45, 50, 54, 57, 62]),
  GuitarTuning('open-e', 'Open E', [40, 47, 52, 56, 59, 64]),
];

GuitarTuning tuningById(String? id) => guitarTunings.firstWhere((t) => t.id == id, orElse: () => guitarTunings.first);

// Česká jména tónů: H = anglické B, B = anglické B♭ (A♯).
const _sharpNames = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'B', 'H'];
const _flatNames = ['C', 'D♭', 'D', 'E♭', 'E', 'F', 'G♭', 'G', 'A♭', 'A', 'B', 'H'];

String noteName(int midi, {bool flats = false}) => (flats ? _flatNames : _sharpNames)[midi % 12];

int noteOctave(int midi) => midi ~/ 12 - 1;

double midiToHz(double midi, {double a4 = 440}) => a4 * math.pow(2, (midi - 69) / 12).toDouble();

double hzToMidi(double hz, {double a4 = 440}) => 69 + 12 * math.log(hz / a4) / math.ln2;

/// Co ladička právě ukazuje.
class TunerOutput {
  const TunerOutput({
    required this.active,
    this.midi,
    this.cents = 0,
    this.hz = 0,
    this.stringIndex,
    this.inTune = false,
  });

  static const idle = TunerOutput(active: false);

  /// Zní tón (nebo doznívá do ~1,2 s od posledního jasného odhadu).
  final bool active;

  /// Cílový tón, ke kterému se ladí (tón struny, jinak nejbližší tón).
  final int? midi;

  /// Odchylka od cíle v centech (+ = vysoko, povolit).
  final double cents;
  final double hz;

  /// Rozpoznaná / vybraná struna (index v `GuitarTuning.midi`), `null` =
  /// chromaticky (tón daleko od všech strun, nebo chromatický režim).
  final int? stringIndex;
  final bool inTune;
}

/// Převádí surové odhady z detektoru (~47×/s) na klidnou ručičku:
/// hradlo na hlasitost a čistotu, přeskočení úderu trsátka, oktávová
/// pojistka, medián + exponenciální vyhlazení, rozpoznání struny s
/// hysterezí a "naladěno" s hysterezí (viz docs/GUITAR_TUNER_RESEARCH.md).
class TunerFilter {
  TunerFilter({required this.tuning, this.a4 = 440, this.targetString, this.chromatic = false});

  GuitarTuning tuning;
  double a4;

  /// Ručně vybraná struna (jinak automaticky).
  int? targetString;
  bool chromatic;

  static const minClarity = 0.86;
  static const attackSkip = Duration(milliseconds: 70);
  static const hold = Duration(milliseconds: 1200);
  static const smoothing = 0.12; // s
  static const inTuneEnter = 3.0; // centy
  static const inTuneExit = 5.0;
  static const inTuneHold = Duration(milliseconds: 300);

  /// Struny, které už byly v téhle relaci naladěné.
  final Set<int> tuned = {};

  double _floor = 0;
  double _lastRms = 0;
  Duration? _onsetAt;
  Duration? _lastValidAt;
  Duration? _lastAt;
  final List<double> _history = [];
  double? _smooth;
  int? _string;
  Duration? _nearSince;
  bool _inTune = false;
  TunerOutput _last = TunerOutput.idle;

  void reset() {
    _history.clear();
    _smooth = null;
    _string = null;
    _nearSince = null;
    _inTune = false;
    _lastValidAt = null;
    _onsetAt = null;
    _last = TunerOutput.idle;
  }

  TunerOutput add(double hz, double clarity, double rms, Duration t) {
    final dt = _lastAt == null ? 0.02 : (t - _lastAt!).inMicroseconds / 1e6;
    _lastAt = t;

    // Hladina šumu: rychle dolů, nahoru jen z odhadů BEZ jasného tónu (šum)
    // -- znějící struna ji nesmí vytáhnout, jinak by hradlo dlouhý tón
    // uřízlo. Start z nízké hodnoty, ať projde i struna, co už zní.
    if (_floor == 0) {
      _floor = math.min(rms, 0.002);
    } else if (rms < _floor) {
      _floor = rms;
    } else if (clarity < 0.5) {
      _floor += (rms - _floor) * 0.05;
    }
    final gate = math.max(0.0015, _floor * 2.5);
    final wasQuiet = _lastRms < gate * 1.5;
    if (rms > gate * 2 && (rms > _lastRms * 2.2 || wasQuiet)) _onsetAt = t;
    _lastRms = rms;

    final inAttack = _onsetAt != null && t - _onsetAt! < attackSkip;
    final valid = hz >= 55 && hz <= 1500 && clarity >= minClarity && rms >= gate && !inAttack;
    if (!valid) {
      if (_lastValidAt == null || t - _lastValidAt! > hold) {
        if (_last.active) reset();
        return _last = TunerOutput.idle;
      }
      return _last; // doznívá: drží poslední hodnotu
    }

    var m = hzToMidi(hz, a4: a4);
    final manual = !chromatic ? targetString : null;
    if (manual != null) {
      // Ruční struna: oktávové omyly (harmonická) sklopit k cíli.
      final target = tuning.midi[manual].toDouble();
      final k = ((m - target) / 12).round();
      if (k != 0 && (m - 12 * k - target).abs() < 0.8) m -= 12 * k;
    }
    if (_history.isNotEmpty) {
      final med = _median();
      if ((m - med).abs() > 0.6) {
        final k = ((m - med) / 12).round();
        if (k != 0 && (m - 12 * k - med).abs() < 0.6) {
          m -= 12 * k; // ojedinělý skok o oktávu = chyba detekce
        } else if ((m - med).abs() > 0.8) {
          _history.clear(); // skutečně jiný tón
          _smooth = null;
          _nearSince = null;
          _inTune = false;
        }
      }
    }
    _history.add(m);
    if (_history.length > 5) _history.removeAt(0);
    final med = _median();
    final s = _smooth;
    _smooth = s == null ? med : s + (med - s) * (1 - math.exp(-dt / smoothing));
    _lastValidAt = t;

    final smooth = _smooth!;
    int? string;
    if (!chromatic) {
      if (manual != null) {
        string = manual;
      } else {
        var best = 0;
        for (var i = 1; i < tuning.midi.length; i++) {
          if ((smooth - tuning.midi[i]).abs() < (smooth - tuning.midi[best]).abs()) best = i;
        }
        final cur = _string;
        if (cur != null &&
            cur < tuning.midi.length &&
            (smooth - tuning.midi[cur]).abs() < (smooth - tuning.midi[best]).abs() + 0.6) {
          best = cur; // hystereze: struna neblikne mezi sousedními
        }
        string = (smooth - tuning.midi[best]).abs() <= 3.5 ? best : null;
      }
    }
    if (string != _string) {
      _nearSince = null;
      _inTune = false;
    }
    _string = string;

    final target = string != null ? tuning.midi[string] : smooth.round();
    final cents = (smooth - target) * 100;

    if (_inTune) {
      if (cents.abs() > inTuneExit) {
        _inTune = false;
        _nearSince = null;
      }
    } else if (cents.abs() < inTuneEnter) {
      _nearSince ??= t;
      if (t - _nearSince! >= inTuneHold) _inTune = true;
    } else {
      _nearSince = null;
    }
    if (_inTune && string != null) tuned.add(string);

    return _last = TunerOutput(
      active: true,
      midi: target,
      cents: cents,
      hz: hz,
      stringIndex: string,
      inTune: _inTune,
    );
  }

  double _median() {
    final sorted = [..._history]..sort();
    return sorted[sorted.length ~/ 2];
  }
}
