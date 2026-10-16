import 'dart:math' as math;

/// Synchronizace sdíleného streamu ("poslouchej se mnou") -- čisté funkce
/// bez Flutteru a přehrávače, ať jdou testovat i simulovat (test/broadcast_sync_test.dart).
///
/// Návrh: jojojo/claude/prace/opentify-noc/7y-sync-navrh.md (v3). Server je
/// jen pošťák s razítkem; posluchač hraje podle poslední kotvy vysílače
/// ("skladba X, pozice P v serverovém čase T, rychlost, hraje") a dopočítává.
/// Všechny časy jsou v ms: klient na monotónních hodinách (`Stopwatch`),
/// server na svém monotónním čase (`clock.pong.s`).

// ---------------------------------------------------------------------------
// Hodiny
// ---------------------------------------------------------------------------

final Stopwatch _mono = Stopwatch()..start();

/// Monotónní čas klienta v ms (neskáče s nastavením hodin; na iOS/Androidu
/// ve spánku stojí -- proto po návratu z pozadí `ClockSync.invalidate`).
double monoNowMs() => _mono.elapsedMicroseconds / 1000.0;

/// Odhad posunu "čas serveru − čas klienta" z dvojic `clock.ping`/`clock.pong`
/// (i z odpovědí HTTP). Bere se vzorek s nejmenším RTT z posledních 8 --
/// zpožděné odpovědi (zátěž, záseky event loopu API) mají větší RTT a prohrají.
class ClockSync {
  ClockSync({this.window = 8, this.minSamples = 3});

  final int window;
  final int minSamples;

  final List<_ClockSample> _samples = [];
  final List<_ClockSample> _deviant = [];
  String? _clockId;

  /// Platný posun (server − klient), nebo `null`, dokud nejsou hodiny změřené
  /// ("hodiny neplatné": po startu, návratu z pozadí, reconnectu, restartu API).
  double? get offsetMs => isValid ? _best!.offset : null;

  /// Nejistota posunu (polovina nejmenšího RTT).
  double get errorMs => _best == null ? double.infinity : _best!.rtt / 2;

  bool get isValid => _samples.length >= minSamples;

  String? get clockId => _clockId;

  _ClockSample? get _best => _samples.isEmpty ? null : _samples.reduce((a, b) => a.rtt <= b.rtt ? a : b);

  double get minRtt => _best?.rtt ?? double.infinity;

  /// Hodiny přestaly platit (monotónní čas na iOS/Androidu ve spánku stojí,
  /// takže starý posun po návratu z pozadí nesedí) -- měřit znovu dávkou.
  void invalidate() {
    _samples.clear();
    _deviant.clear();
  }

  /// `c0` odeslání, `c1` příjem (klient), `s` čas serveru, `clockId` id procesu
  /// serveru. Vrací, jestli se vzorek použil.
  bool add({required double c0, required double c1, required double s, required String clockId}) {
    if (clockId != _clockId) {
      // Restart API: jiné hodiny serveru -- všechno staré pryč.
      _clockId = clockId;
      invalidate();
    }
    final rtt = c1 - c0;
    if (rtt < 0 || rtt > 10000) return false;
    final sample = _ClockSample(offset: s - (c0 + c1) / 2, rtt: rtt);
    final best = _best;
    if (best != null && _samples.length >= minSamples && rtt > 2 * best.rtt + 4) return false;
    if (isValid && (sample.offset - best!.offset).abs() > 50) {
      // Posun se změnil (spánek, krok hodin)? Až když se na tom shodnou 3
      // vzorky po sobě -- jeden zpožděný pong nesmí zahodit dobré okno.
      _deviant.add(sample);
      if (_deviant.length >= 3) {
        final offs = _deviant.map((d) => d.offset).toList();
        final spread = offs.reduce(math.max) - offs.reduce(math.min);
        if (spread <= 50) {
          _samples
            ..clear()
            ..addAll(_deviant);
          _deviant.clear();
          return true;
        }
        _deviant.removeAt(0);
      }
      return false;
    }
    _deviant.clear();
    _samples.add(sample);
    if (_samples.length > window) _samples.removeAt(0);
    return true;
  }

  /// Čas serveru teď (`null` bez platných hodin).
  double? serverNow(double clientNowMs) {
    final o = offsetMs;
    return o == null ? null : clientNowMs + o;
  }
}

class _ClockSample {
  const _ClockSample({required this.offset, required this.rtt});
  final double offset;
  final double rtt;
}

// ---------------------------------------------------------------------------
// Kotva a cílová pozice
// ---------------------------------------------------------------------------

/// Kotva vysílače: kde a co hraje v serverovém čase. Tvar 1:1 s
/// `broadcast.state.anchor` (backend app/broadcast.py `clean_anchor`).
class BroadcastAnchor {
  const BroadcastAnchor({
    required this.recordingId,
    required this.index,
    required this.positionMs,
    required this.atServerMs,
    this.qv = 0,
    this.epoch = 0,
    this.rate = 1.0,
    this.isPlaying = false,
    this.durationMs,
    this.repeatMode = 'off',
    this.startAtServerMs,
    this.transitionAtServerMs,
    this.clockOk = true,
  });

  final String recordingId;
  final int index;
  final int qv;

  /// Roste u vysílače při každé nespojitosti (jiná skladba, seek, pauza/play,
  /// rychlost) -- heartbeat ve stejné epoše je jen měření (viz `TimelineModel`).
  final int epoch;
  final double positionMs;
  final double atServerMs;
  final double rate;
  final bool isPlaying;

  /// Skutečná délka z přehrávače vysílače (ne metadata, recenze K4).
  final double? durationMs;
  final String repeatMode;

  /// Plánovaný start (přeskok / play): oba začnou v tomhle čase od `positionMs`.
  final double? startAtServerMs;

  /// Plánovaný přirozený přechod na další skladbu.
  final double? transitionAtServerMs;

  /// Vysílač měl při odeslání platné hodiny -- jinak se pozice nepoužívá a
  /// plán chybí (N7).
  final bool clockOk;

  factory BroadcastAnchor.fromJson(Map<String, dynamic> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    return BroadcastAnchor(
      recordingId: j['recordingId'] as String,
      index: (j['index'] as num?)?.toInt() ?? 0,
      qv: (j['qv'] as num?)?.toInt() ?? 0,
      epoch: (j['epoch'] as num?)?.toInt() ?? 0,
      positionMs: d('positionMs') ?? 0,
      atServerMs: d('atServerMs') ?? 0,
      rate: d('rate') ?? 1.0,
      isPlaying: j['isPlaying'] as bool? ?? false,
      durationMs: d('durationMs'),
      repeatMode: j['repeatMode'] as String? ?? 'off',
      startAtServerMs: d('startAtServerMs'),
      transitionAtServerMs: d('transitionAtServerMs'),
      clockOk: j['clockOk'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'recordingId': recordingId,
        'index': index,
        'qv': qv,
        'epoch': epoch,
        'positionMs': positionMs.round(),
        'atServerMs': atServerMs,
        'rate': rate,
        'isPlaying': isPlaying,
        if (durationMs != null) 'durationMs': durationMs!.round(),
        'repeatMode': repeatMode,
        if (startAtServerMs != null) 'startAtServerMs': startAtServerMs,
        if (transitionAtServerMs != null) 'transitionAtServerMs': transitionAtServerMs,
        'clockOk': clockOk,
      };

  BroadcastAnchor copyWith({double? positionMs, double? durationMs, double? transitionAtServerMs, bool clearTransition = false}) =>
      BroadcastAnchor(
        recordingId: recordingId,
        index: index,
        qv: qv,
        epoch: epoch,
        positionMs: positionMs ?? this.positionMs,
        atServerMs: atServerMs,
        rate: rate,
        isPlaying: isPlaying,
        durationMs: durationMs ?? this.durationMs,
        repeatMode: repeatMode,
        startAtServerMs: startAtServerMs,
        transitionAtServerMs: clearTransition ? null : (transitionAtServerMs ?? this.transitionAtServerMs),
        clockOk: clockOk,
      );
}

/// Kde má posluchač být: položka fronty (absolutní index vysílače), pozice
/// v ní a jestli má hrát. `waitingForStart`: plánovaný start ještě nenastal.
class SyncTarget {
  const SyncTarget({required this.index, required this.positionMs, required this.playing, this.waitingForStart = false, this.ended = false});
  final int index;
  final double positionMs;
  final bool playing;
  final bool waitingForStart;

  /// Dopočet došel za konec fronty (vysílač dohrál).
  final bool ended;

  @override
  String toString() => 'SyncTarget($index, ${positionMs.round()} ms, ${playing ? 'hraje' : 'stojí'}${waitingForStart ? ', čeká na start' : ''})';
}

/// Rezerva přechodu: plánovaný přechod je tolik před koncem skladby, ať ho
/// stihne každá platforma (web dřív přepínal 600 ms před koncem vždy).
const transitionMarginMs = 300.0;

/// Cílová pozice v serverovém čase `serverNow`. Přes konec skladby jde podle
/// plánu přechodu (`transitionAtServerMs`), dál (výpadek spojení) podle
/// délek položek `durationOf` -- vždy s rezervou `transitionMarginMs`.
/// `queueEnd` = první index za frontou (konec, když neopakuje).
SyncTarget targetAt(
  BroadcastAnchor a,
  double serverNow, {
  double? Function(int index)? durationOf,
  int? queueEnd,
}) {
  if (!a.isPlaying) return SyncTarget(index: a.index, positionMs: a.positionMs, playing: false);
  // Plán startu platí jen pro kotvu, která ho popisuje (pozice V čase startu,
  // `atServerMs == startAtServerMs`). Kotva změřená až po rozjezdu nese
  // vlastní čas -- počítat od startu by uběhlý čas započítalo dvakrát
  // (živě 16. 10.: posluchač o 30 s napřed a seekoval dokola).
  final start = (a.startAtServerMs != null && a.atServerMs <= a.startAtServerMs! + 1) ? a.startAtServerMs : null;
  if (start != null && serverNow < start) {
    return SyncTarget(index: a.index, positionMs: a.positionMs, playing: false, waitingForStart: true);
  }
  final t0 = start ?? a.atServerMs;
  var index = a.index;
  var pos = a.positionMs + (serverNow - t0) * a.rate;
  // První přechod: plán vysílače, jinak skutečná délka.
  final plan = a.transitionAtServerMs ??
      (a.durationMs == null ? null : t0 + (a.durationMs! - transitionMarginMs - a.positionMs) / a.rate);
  if (plan == null || serverNow < plan) return SyncTarget(index: index, positionMs: pos, playing: true);
  pos = (serverNow - plan) * a.rate;
  index = _nextIndex(index, a.repeatMode);
  // Další přechody jen dopočtem (vysílač mezitím nedorazil).
  for (var guard = 0; guard < 1000; guard++) {
    if (queueEnd != null && index >= queueEnd && a.repeatMode != 'one') {
      return SyncTarget(index: queueEnd - 1, positionMs: 0, playing: false, ended: true);
    }
    final dur = durationOf?.call(index);
    if (dur == null || pos < dur - transitionMarginMs) break;
    pos -= dur - transitionMarginMs;
    index = _nextIndex(index, a.repeatMode);
  }
  return SyncTarget(index: index, positionMs: pos, playing: true);
}

int _nextIndex(int index, String repeatMode) => repeatMode == 'one' ? index : index + 1;

/// Model časové osy vysílače u posluchače. Nová kotva ve stejné epoše
/// (heartbeat) se nepřebírá skokem -- je to jen další měření s chybou
/// ±10-30 ms a skákání cíle by regulátor honil (recenze S1).
class TimelineModel {
  BroadcastAnchor? anchor;

  /// Vrací `true`, když jde o nespojitost (posluchač má hned jednat).
  bool apply(BroadcastAnchor next) {
    final cur = anchor;
    // Vysílač bez platných hodin (po startu, po návratu z pozadí): pozice
    // v jeho kotvě je jen přibližná (čas přerazítkoval server). U téže
    // skladby ve stejném stavu ji nebrat -- jinak by každý takový heartbeat
    // posunul cíl a regulátor by seekoval.
    if (cur != null && !next.clockOk && cur.clockOk && _sameEpoch(cur, next)) return false;
    if (cur == null || !_sameEpoch(cur, next) || !next.clockOk || !cur.clockOk) {
      anchor = next;
      return true;
    }
    if (!next.isPlaying) {
      anchor = next;
      return false;
    }
    final predicted = cur.positionMs + (next.atServerMs - cur.atServerMs) * cur.rate;
    final r = next.positionMs - predicted;
    // Plán a délka z novější kotvy platí vždy, pozice jen vyhlazeně.
    BroadcastAnchor merged(double pos) => BroadcastAnchor(
          recordingId: next.recordingId,
          index: next.index,
          qv: next.qv,
          epoch: next.epoch,
          positionMs: pos,
          atServerMs: next.atServerMs,
          rate: next.rate,
          isPlaying: true,
          durationMs: next.durationMs ?? cur.durationMs,
          repeatMode: next.repeatMode,
          // Plán startu jen z novější kotvy: změřená kotva po rozjezdu ho už
          // nemá a starý plán by uběhlý čas započítal dvakrát.
          startAtServerMs: next.startAtServerMs,
          transitionAtServerMs: next.transitionAtServerMs ?? cur.transitionAtServerMs,
          clockOk: true,
        );
    if (r.abs() > 250) {
      anchor = next; // něco se změnilo a vysílač nezvedl epochu
      return true;
    }
    anchor = merged(r.abs() < 20 ? predicted : predicted + 0.3 * r);
    return false;
  }

  static bool _sameEpoch(BroadcastAnchor a, BroadcastAnchor b) =>
      a.epoch == b.epoch && a.recordingId == b.recordingId && a.index == b.index && a.isPlaying == b.isPlaying && a.rate == b.rate;
}

// ---------------------------------------------------------------------------
// Plánovaný start a přechod
// ---------------------------------------------------------------------------

/// Zdržení plánovaného startu po přeskoku / play u vysílače s posluchači:
/// nejdelší příprava posluchačů + jednosměrná latence, 300-1200 ms (play po
/// pauze nejvýš 400 ms -- audio je u všech načtené).
double plannedStartDelayMs({int? prepMs, double oneWayMs = 30, bool resume = false}) {
  if (resume) return (oneWayMs + 100).clamp(150, 400).toDouble();
  if (prepMs == null) return 600;
  return (prepMs + oneWayMs).clamp(300, 1200).toDouble();
}

/// Plán přirozeného přechodu ze skutečné délky (K4): serverový čas, kdy oba
/// začnou další skladbu.
double plannedTransitionAt({required double atServerMs, required double positionMs, required double durationMs, double rate = 1.0}) =>
    atServerMs + (durationMs - transitionMarginMs - positionMs) / rate;

/// Kdy začít načítat další skladbu, aby v čase `x` hrála (N3): jeden
/// přehrávač nenačte další zdroj, dokud hraje současný. Načítání smí useknout
/// nejvýš tolik, aby s rezervou přechodu šlo o 600 ms z konce skladby; co se
/// nevejde, dorovná regulátor. `safetyMs`: načítání kolísá -- radši být
/// připravený o chvilku dřív a na start počkat.
double loadAt({required double x, required double loadLeadMs, required double startLeadMs, double safetyMs = 100}) =>
    x - math.min(loadLeadMs + startLeadMs + safetyMs, 600 - transitionMarginMs);

/// Klouzavý průměr doby (příprava, načtení, rozjezd), odolný proti úletům.
class LeadEstimate {
  LeadEstimate(this.valueMs, {this.alpha = 0.3, this.maxMs = 3000});
  double valueMs;
  final double alpha;
  final double maxMs;

  void add(double sampleMs) {
    if (sampleMs.isNaN || sampleMs < 0) return;
    valueMs += alpha * (math.min(sampleMs, maxMs) - valueMs);
  }
}

// ---------------------------------------------------------------------------
// Regulátor
// ---------------------------------------------------------------------------

enum SyncActionKind { none, setRate, seek }

class SyncAction {
  const SyncAction.none()
      : kind = SyncActionKind.none,
        rate = null,
        leadMs = 0;
  const SyncAction.rate(double this.rate)
      : kind = SyncActionKind.setRate,
        leadMs = 0;
  const SyncAction.seek(this.leadMs)
      : kind = SyncActionKind.seek,
        rate = null;

  final SyncActionKind kind;
  final double? rate;

  /// Seek na `cíl + leadMs` (o kolik dřív seek hraje, než je slyšet).
  final double leadMs;

  @override
  String toString() => switch (kind) {
        SyncActionKind.none => 'nic',
        SyncActionKind.setRate => 'rychlost $rate',
        SyncActionKind.seek => 'seek +${leadMs.round()} ms',
      };
}

/// Dorovnání odchylky `e = skutečná − cílová pozice` (kladná = posluchač je
/// napřed). Malé odchylky plynule rychlostí (±1/±2 %), velké jedním seekem.
/// Pojistky: usazení po každém zásahu, držení rychlosti, nejvýš 1 seek za 3 s,
/// volný režim s rostoucí délkou (návrh bod 6, recenze S1, S2, N5).
class SyncRegulator {
  SyncRegulator({this.canRate = true});

  /// Platforma umí plynule měnit rychlost (jinak jen práh + seek).
  bool canRate;

  static const tauMs = 2000.0;
  static const settleMs = 1000.0;
  static const holdMs = 3000.0;
  static const minRateGapMs = 2000.0;
  static const seekGapMs = 3000.0;
  static const seekThresholdMs = 350.0;
  static const thresholdOnlyDeadbandMs = 60.0;
  static const thresholdOnlySeekMs = 250.0;
  static const looseSeekMs = 2000.0;

  double? _filtered;
  double _var = 0;
  double? _lastSampleAt;
  double _settleUntil = -1e18;
  int _step = 0; // −2..2 = rychlost base × (1 − step %)
  double _lastRateChange = -1e18;
  double? _stepStartedAt;
  double _stepStartedErr = 0;
  bool _rateFailed = false;

  final List<double> _seeks = [];
  double _looseUntil = -1e18;
  int _looseLevel = 0;
  double _lastTrouble = -1e18;
  double _freshUntil = -1e18;
  static const freshSeekMs = 100.0;

  /// Odhad, o kolik dřív seek hraje, než je slyšet -- zvlášť soubor v cache
  /// a stream; opravuje se zbytkovou chybou po každém seeku (S2).
  final Map<bool, double> seekLead = {true: 120, false: 400};
  bool? _pendingSeekCached;
  int _postSeekSamples = 0;

  /// Počítadla pro testy a diagnostiku.
  int rateChanges = 0;
  int seeks = 0;

  bool get looseMode => _now < _looseUntil;
  bool get rateFailed => _rateFailed;
  int get step => _step;
  double? get filteredErrorMs => _filtered;
  double _now = 0;

  /// Pásmo necitlivosti: 2σ šumu měření, nejméně 20 ms (filtr přes 2 s šum
  /// jednotlivých čtení ±10-30 ms stáhne na jednotky ms), nejvýš 80 ms.
  double get deadbandMs => _rateFailed || !canRate ? thresholdOnlyDeadbandMs : math.max(20, math.min(80, 2 * math.sqrt(_var)));

  /// Po seeku / startu / play / `setSpeed`: just_audio hlásí novou pozici dřív,
  /// než je zvuk slyšet -- chvíli neměřit a filtr začít znovu.
  void settle(double nowMs) {
    _settleUntil = nowMs + settleMs;
    _filtered = null;
    _lastSampleAt = null;
  }

  /// Úplný reset (nová skladba, nové připojení). Naučené `seekLead` zůstávají.
  /// Hned po připojení / startu skladby je seek neslyšitelný (zvuk teprve
  /// začíná), tak první větší odchylku srovnat seekem, ne 15 s rychlostí.
  void reset(double nowMs) {
    settle(nowMs);
    _freshUntil = nowMs + settleMs + 3000;
    _step = 0;
    _stepStartedAt = null;
    _pendingSeekCached = null;
  }

  double rateFor(double base) => base * (1 - _step / 100);

  /// Jedno měření (každých ~250 ms za přehrávání). `cached`: hraje se ze
  /// souboru v cache (kratší seek).
  SyncAction observe({required double nowMs, required double errorMs, double baseRate = 1.0, bool cached = true}) {
    _now = nowMs;
    if (nowMs < _settleUntil) return const SyncAction.none();
    // Filtr: EWMA s časovou konstantou 2 s + rozptyl kolem něj (šum měření).
    final last = _lastSampleAt;
    _lastSampleAt = nowMs;
    if (_filtered == null || last == null) {
      _filtered = errorMs;
    } else {
      final alpha = 1 - math.exp(-(nowMs - last) / tauMs);
      final d = errorMs - _filtered!;
      _filtered = _filtered! + alpha * d;
      _var = (1 - alpha) * (_var + alpha * d * d);
    }
    // Zbytek po seeku -> oprava seekLead (po 4 měřeních po usazení).
    if (_pendingSeekCached != null && ++_postSeekSamples >= 4) {
      final k = _pendingSeekCached!;
      seekLead[k] = (seekLead[k]! - 0.5 * _filtered!).clamp(0, 1500).toDouble();
      _pendingSeekCached = null;
    }
    // Filtr se za skutečností opožďuje o (rychlost korekce × τ) -- se svou
    // známou korekcí počítat, jinak by regulátor přestřelil (N5).
    final correction = (rateFor(baseRate) - baseRate) / baseRate; // např. −0,02
    final e = _filtered! + correction * tauMs;
    final mag = e.abs();
    if (nowMs - _lastTrouble > 10 * 60 * 1000) _looseLevel = 0; // 10 min klid

    var seekAt = looseMode ? looseSeekMs : (_rateFailed || !canRate ? thresholdOnlySeekMs : seekThresholdMs);
    if (nowMs < _freshUntil && !looseMode) seekAt = math.min(seekAt, freshSeekMs);
    if (mag > seekAt) {
      if (nowMs - (_seeks.isEmpty ? -1e18 : _seeks.last) < seekGapMs) return const SyncAction.none();
      return _seek(nowMs, cached, baseRate);
    }
    if (_rateFailed || !canRate) return const SyncAction.none();

    // Plynulá korekce selhává: za 10 s se odchylka nezmenšila aspoň o 30 %.
    if (_step != 0 && _stepStartedAt != null && nowMs - _stepStartedAt! > 10000) {
      if (mag > 0.7 * _stepStartedErr) {
        _rateFailed = true;
        return _setStep(0, nowMs);
      }
      _stepStartedAt = nowMs;
      _stepStartedErr = mag;
    }
    final d = deadbandMs;
    int want;
    if (mag < d / 2) {
      want = 0;
    } else if (mag >= d) {
      want = (mag > 120 ? 2 : 1) * (e > 0 ? 1 : -1);
    } else {
      want = _step; // hystereze
      if (want != 0 && (want > 0) != (e > 0)) want = 0; // přestřelilo -> stop
    }
    if (want == _step) return const SyncAction.none();
    if (nowMs - _lastRateChange < holdMs || nowMs - _lastRateChange < minRateGapMs) return const SyncAction.none();
    if (_step == 0) {
      _stepStartedAt = nowMs;
      _stepStartedErr = mag;
    }
    return _setStep(want, nowMs, baseRate: baseRate);
  }

  /// `setSpeed` hodil výjimku -- dál jen práh + seek.
  void rateUnsupported() {
    _rateFailed = true;
    _step = 0;
  }

  SyncAction _setStep(int step, double nowMs, {double baseRate = 1.0}) {
    _step = step;
    if (step == 0) _stepStartedAt = null;
    _lastRateChange = nowMs;
    rateChanges++;
    // Usazení po změně rychlosti krátké -- just_audio extrapoluje novou
    // rychlostí hned, platforma ji použije o chvilku později.
    _settleUntil = nowMs + 300;
    return SyncAction.rate(rateFor(baseRate));
  }

  SyncAction _seek(double nowMs, bool cached, double baseRate) {
    _seeks.add(nowMs);
    _seeks.removeWhere((t) => nowMs - t > 30000);
    seeks++;
    _lastTrouble = nowMs;
    if (_seeks.length >= 3 && !looseMode) {
      // Seek bouře -> volný režim, pokaždé delší (60 -> 120 -> 240 -> 600 s).
      const levels = [60000.0, 120000.0, 240000.0, 600000.0];
      _looseUntil = nowMs + levels[math.min(_looseLevel, levels.length - 1)];
      _looseLevel++;
      _seeks.clear();
    }
    _step = 0;
    _stepStartedAt = null;
    _pendingSeekCached = cached;
    _postSeekSamples = 0;
    _freshUntil = -1e18;
    settle(nowMs);
    return SyncAction.seek(seekLead[cached]! * baseRate);
  }
}

/// Měření pozice je použitelné jen, když čas "na zdi" běžel stejně jako
/// monotónní: just_audio extrapoluje pozici z `DateTime.now()` a skok hodin
/// zařízení by se tvářil jako skok přehrávání.
bool positionSampleUsable({required double wallDeltaMs, required double monoDeltaMs}) => (wallDeltaMs - monoDeltaMs).abs() <= 50;
