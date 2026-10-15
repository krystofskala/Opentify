import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/broadcast_sync.dart';

/// Sdílený stream: hodiny, cílová pozice, regulátor, plánovaný start --
/// a simulace s virtuálním časem podle návrhu (7y-sync-navrh.md v3, bod 10):
/// síť jako TCP (zpoždění, shluky, výpadky -- bez ztrát a přeházení v jednom
/// spojení), nedokonalý přehrávač (pozice po seeku hlášená dřív, než je
/// slyšet, zpoždění setSpeed, drift zvukových hodin zvlášť od systémových),
/// kritéria na SKUTEČNÝ posun zvuku, ne na odhad regulátoru.
void main() {
  group('ClockSync', () {
    test('bere vzorek s nejmenším RTT a zahodí zpožděné', () {
      final c = ClockSync();
      // Skutečný posun 1000 ms; RTT 20/60/10 ms (symetricky).
      c.add(c0: 0, c1: 20, s: 1010, clockId: 'a');
      c.add(c0: 100, c1: 160, s: 1130, clockId: 'a');
      expect(c.isValid, isFalse); // dávka ještě neskončila
      c.add(c0: 200, c1: 210, s: 1205, clockId: 'a');
      expect(c.offsetMs, 1000);
      // Zpožděný pong (RTT 300, jednosměrně): neprojde filtrem.
      expect(c.add(c0: 300, c1: 600, s: 1590, clockId: 'a'), isFalse);
      expect(c.offsetMs, 1000);
    });

    test('jeden úlet okno nezahodí, tři shodné po sobě ano', () {
      final c = ClockSync();
      for (var i = 0; i < 4; i++) {
        c.add(c0: i * 100.0, c1: i * 100.0 + 10, s: i * 100.0 + 5 + 1000, clockId: 'a');
      }
      expect(c.offsetMs, 1000);
      c.add(c0: 500, c1: 510, s: 505 + 1200, clockId: 'a'); // jeden úlet
      expect(c.offsetMs, 1000);
      c.add(c0: 600, c1: 610, s: 605 + 1000, clockId: 'a'); // zpátky normál -> úlety pryč
      for (var i = 0; i < 3; i++) {
        c.add(c0: 700.0 + i * 100, c1: 710.0 + i * 100, s: 705.0 + i * 100 + 1200, clockId: 'a');
      }
      expect(c.offsetMs, 1200); // spánek / krok hodin: shodly se tři
    });

    test('jiné clockId (restart API) a návrat z pozadí = hodiny neplatné', () {
      final c = ClockSync();
      for (var i = 0; i < 3; i++) {
        c.add(c0: i * 10.0, c1: i * 10.0 + 4, s: i * 10.0 + 2 + 500, clockId: 'a');
      }
      expect(c.isValid, isTrue);
      c.add(c0: 100, c1: 104, s: 102 + 9000, clockId: 'b');
      expect(c.isValid, isFalse);
      expect(c.serverNow(0), isNull);
      for (var i = 0; i < 3; i++) {
        c.add(c0: 200.0 + i, c1: 204.0 + i, s: 202.0 + i + 9000, clockId: 'b');
      }
      expect(c.offsetMs, 9000);
      c.invalidate();
      expect(c.offsetMs, isNull);
    });
  });

  group('targetAt', () {
    const a = BroadcastAnchor(recordingId: 'x', index: 3, positionMs: 10000, atServerMs: 50000, isPlaying: true, durationMs: 200000);

    test('dopočet pozice, pauza a rychlost', () {
      expect(targetAt(a, 52000).positionMs, 12000);
      const paused = BroadcastAnchor(recordingId: 'x', index: 3, positionMs: 10000, atServerMs: 50000);
      expect(targetAt(paused, 99000).positionMs, 10000);
      expect(targetAt(paused, 99000).playing, isFalse);
      const fast = BroadcastAnchor(recordingId: 'x', index: 3, positionMs: 0, atServerMs: 0, rate: 1.5, isPlaying: true);
      expect(targetAt(fast, 1000).positionMs, 1500);
    });

    test('plánovaný start: do startu stojí na pozici, pak hraje od ní', () {
      const s = BroadcastAnchor(recordingId: 'x', index: 0, positionMs: 0, atServerMs: 1000, startAtServerMs: 1600, isPlaying: true);
      final before = targetAt(s, 1500);
      expect(before.waitingForStart, isTrue);
      expect(before.playing, isFalse);
      expect(targetAt(s, 1700).positionMs, 100);
    });

    test('přes konec skladby podle plánu přechodu, dál podle délek, konec fronty', () {
      final withPlan = BroadcastAnchor(
        recordingId: 'x', index: 3, positionMs: 10000, atServerMs: 50000, isPlaying: true, durationMs: 20000,
        transitionAtServerMs: plannedTransitionAt(atServerMs: 50000, positionMs: 10000, durationMs: 20000),
      );
      // Přechod v 50000 + (20000 − 300 − 10000) = 59700.
      expect(targetAt(withPlan, 59600).index, 3);
      final after = targetAt(withPlan, 60700);
      expect(after.index, 4);
      expect(after.positionMs, 1000);
      // Výpadek: další skladby (délka 30 s) dopočtem.
      final far = targetAt(withPlan, 59700 + 29700 + 500, durationOf: (_) => 30000);
      expect(far.index, 5);
      expect(far.positionMs, 500);
      final end = targetAt(withPlan, 59700 + 5000, durationOf: (_) => 30000, queueEnd: 4);
      expect(end.ended, isTrue);
      // Opakovat skladbu: zůstává stejná položka.
      const one = BroadcastAnchor(recordingId: 'x', index: 3, positionMs: 0, atServerMs: 0, isPlaying: true, durationMs: 10000, repeatMode: 'one');
      expect(targetAt(one, 10000).index, 3);
    });
  });

  group('TimelineModel', () {
    BroadcastAnchor hb(double pos, double at, {int epoch = 1, String rid = 'x'}) =>
        BroadcastAnchor(recordingId: rid, index: 0, positionMs: pos, atServerMs: at, isPlaying: true, epoch: epoch);

    test('heartbeat se šumem se vyhladí, nespojitost přepíše', () {
      final m = TimelineModel();
      expect(m.apply(hb(0, 0)), isTrue);
      expect(m.apply(hb(10010, 10000)), isFalse); // 10 ms šum -> beze změny
      expect(targetAt(m.anchor!, 10000).positionMs, 10000);
      m.apply(hb(20050, 20000)); // 50 ms -> posun o 30 %
      expect(targetAt(m.anchor!, 20000).positionMs, closeTo(20015, 0.01));
      expect(m.apply(hb(5000, 30000, epoch: 2)), isTrue); // seek
      expect(m.anchor!.positionMs, 5000);
      expect(m.apply(hb(15000, 31000, epoch: 2)), isTrue); // velký skok bez nové epochy
    });

    test('plán přechodu z novější kotvy se převezme', () {
      final m = TimelineModel()..apply(hb(0, 0));
      m.apply(const BroadcastAnchor(recordingId: 'x', index: 0, positionMs: 5000, atServerMs: 5000, isPlaying: true, epoch: 1, transitionAtServerMs: 9000));
      expect(m.anchor!.transitionAtServerMs, 9000);
    });
  });

  group('plánování', () {
    test('zdržení startu a načítání před přechodem', () {
      expect(plannedStartDelayMs(), 600);
      expect(plannedStartDelayMs(prepMs: 100), 300);
      expect(plannedStartDelayMs(prepMs: 5000), 1200);
      expect(plannedStartDelayMs(resume: true, oneWayMs: 900), 400);
      // Načítání se vejde -> o celou přípravu dřív; nevejde -> nejvýš 300 ms.
      expect(loadAt(x: 10000, loadLeadMs: 100, startLeadMs: 40), 10000 - 240);
      expect(loadAt(x: 10000, loadLeadMs: 900, startLeadMs: 40), 9700);
    });
  });

  group('SyncRegulator', () {
    test('malá odchylka -> plynule, velká -> seek, pak usazení', () {
      final r = SyncRegulator();
      var a = r.observe(nowMs: 0, errorMs: 80);
      expect(a.kind, SyncActionKind.setRate);
      expect(a.rate, 0.99); // posluchač napřed -> zpomalit
      final s = SyncRegulator();
      a = s.observe(nowMs: 0, errorMs: -900);
      expect(a.kind, SyncActionKind.seek);
      expect(a.leadMs, 120);
      expect(s.observe(nowMs: 500, errorMs: -900).kind, SyncActionKind.none); // usazení
    });

    test('nejvýš 1 seek za 3 s a po bouři volný režim s rostoucí délkou', () {
      final r = SyncRegulator();
      var t = 0.0;
      var n = 0;
      for (var i = 0; i < 200; i++, t += 250) {
        if (r.observe(nowMs: t, errorMs: 1000).kind == SyncActionKind.seek) n++;
      }
      // 50 s, seeky po 3 s by byly ~16; volný režim (60 s, práh 2 s) je zastaví po 3.
      expect(n, 3);
      expect(r.looseMode, isTrue);
    });

    test('setSpeed nefunguje -> jen práh', () {
      final r = SyncRegulator()..rateUnsupported();
      expect(r.observe(nowMs: 0, errorMs: 200).kind, SyncActionKind.none);
      // Filtr (2 s) se k 400 ms dostane přes práh 250 ms za chvilku.
      var seeked = false;
      for (var t = 250.0; t < 4000 && !seeked; t += 250) {
        final a = r.observe(nowMs: t, errorMs: 400);
        expect(a.kind, isNot(SyncActionKind.setRate));
        seeked = a.kind == SyncActionKind.seek;
      }
      expect(seeked, isTrue);
    });

    test('zbytková chyba po seeku opraví seekLead', () {
      final r = SyncRegulator();
      r.observe(nowMs: 0, errorMs: -1000);
      // Po usazení je posluchač 100 ms napřed -> lead byl moc velký.
      for (var t = 1250.0; t < 3000; t += 250) {
        r.observe(nowMs: t, errorMs: 100);
      }
      expect(r.seekLead[true], lessThan(120));
    });
  });

  group('simulace', () {
    test('ustálený stav: p95 skutečného posunu < 40 ms, bez seek bouře a kmitání', () {
      final res = _simulate(seed: 1, minutes: 10, initialErrorMs: 500);
      expect(res.p95SteadyMs, lessThan(40), reason: res.toString());
      expect(res.maxSeeksIn3s, lessThanOrEqualTo(1), reason: res.toString());
      expect(res.rateChangesPerMinSteady, lessThanOrEqualTo(2), reason: res.toString());
      expect(res.settledWithinMs, lessThan(10000), reason: res.toString());
    });

    test('víc semínek a horší síť (shluky, výpadky), dva posluchači navzájem', () {
      for (final seed in [2, 3, 4, 5]) {
        final a = _simulate(seed: seed, minutes: 5, initialErrorMs: -1500, burstyNet: true);
        final b = _simulate(seed: seed + 100, minutes: 5, initialErrorMs: 300, burstyNet: true);
        expect(a.p95SteadyMs, lessThan(40), reason: 'seed $seed: $a');
        expect(b.p95SteadyMs, lessThan(40), reason: 'seed $seed: $b');
        expect(a.maxSeeksIn3s, lessThanOrEqualTo(1));
        // Mezi dvěma posluchači: oba proti vysílači < 40 ms -> navzájem p95 < 80 ms
        // v nejhorším; skutečně porovnáno ze stejné časové osy:
        final mutual = _mutualP95(a.trace, b.trace);
        expect(mutual, lessThan(60), reason: 'seed $seed: mutual $mutual');
      }
    });

    test('10 přirozených přechodů: max posun v prvních 3 s po přechodu < 80 ms', () {
      final rnd = math.Random(7);
      final loadB = LeadEstimate(150), startB = LeadEstimate(50);
      final loadL = LeadEstimate(150), startL = LeadEstimate(50);
      var worst = 0.0;
      for (var i = 0; i < 10; i++) {
        const x = 100000.0; // plánovaný přechod (serverový čas)
        double startOf(LeadEstimate load, LeadEstimate start, double loadMean, double startMean) {
          final loadActual = loadMean + _gauss(rnd) * 30;
          final startActual = startMean + _gauss(rnd) * 8;
          final callLoad = loadAt(x: x, loadLeadMs: load.valueMs, startLeadMs: start.valueMs);
          final ready = callLoad + loadActual;
          final playCall = math.max(ready, x - start.valueMs);
          load.add(loadActual);
          start.add(startActual);
          return playCall + startActual; // kdy je zvuk skutečně slyšet
        }

        // Vysílač z cache (web), posluchač nativně s pomalejším načítáním.
        final b = startOf(loadB, startB, 120, 40);
        final l = startOf(loadL, startL, 180, 60);
        // Plánovaný start: chyba je rozdíl skutečných startů (pozice obou
        // počítají od svého startu), regulátor se 1 s usazuje -> 3 s ~ tahle chyba.
        worst = math.max(worst, (b - l).abs());
      }
      expect(worst, lessThan(80));
    });
  });
}

double _gauss(math.Random r) {
  // Box-Muller
  final u1 = r.nextDouble().clamp(1e-12, 1.0);
  final u2 = r.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

class _SimResult {
  _SimResult(this.p95SteadyMs, this.maxSeeksIn3s, this.rateChangesPerMinSteady, this.settledWithinMs, this.trace);
  final double p95SteadyMs;
  final int maxSeeksIn3s;
  final double rateChangesPerMinSteady;
  final double settledWithinMs;

  /// (čas, skutečná pozice zvuku posluchače − vysílače)
  final List<(double, double)> trace;

  @override
  String toString() =>
      'p95=${p95SteadyMs.toStringAsFixed(1)} ms, seeky/3s=$maxSeeksIn3s, rychlost/min=${rateChangesPerMinSteady.toStringAsFixed(2)}, usazeno=${settledWithinMs.round()} ms';
}

double _mutualP95(List<(double, double)> a, List<(double, double)> b) {
  final n = math.min(a.length, b.length);
  final diffs = <double>[];
  for (var i = 0; i < n; i++) {
    if (a[i].$1 < 30000) continue;
    diffs.add((a[i].$2 - b[i].$2).abs());
  }
  diffs.sort();
  return diffs.isEmpty ? 0 : diffs[(diffs.length * 0.95).floor().clamp(0, diffs.length - 1)];
}

/// Jeden posluchač proti vysílači. Virtuální čas po 10 ms.
_SimResult _simulate({required int seed, required int minutes, required double initialErrorMs, bool burstyNet = false}) {
  final rnd = math.Random(seed);
  const dt = 10.0;
  final total = minutes * 60000.0;
  // Hodiny: zvukové (DAC) proti systémovým zvlášť.
  final dacB = 1 + (rnd.nextDouble() - 0.5) * 100e-6; // ±50 ppm
  final dacL = 1 + (rnd.nextDouble() - 0.5) * 100e-6;
  final sysL = 1 + (rnd.nextDouble() - 0.5) * 200e-6; // ±100 ppm systémové hodiny posluchače
  // Zbytková chyba odhadu posunu (asymetrie trasy), u obou stran.
  final clockErrB = (rnd.nextDouble() - 0.5) * 10;
  final clockErrL = (rnd.nextDouble() - 0.5) * 10;

  // Vysílač: zvuk běží od t=0 od pozice 0.
  double bPos(double t) => t * dacB;

  // Posluchač: skutečný zvuk.
  var lPos = bPos(0) + initialErrorMs;
  var lRate = 1.0;
  double? pendingRate;
  var pendingRateAt = 0.0;
  var silentUntil = -1.0; // po seeku chvíli ticho, pozice stojí
  var silentTarget = 0.0;
  var reportedOverride = false;

  final model = TimelineModel();
  final reg = SyncRegulator()..reset(0); // připojení
  // Kotvy v "síti": (čas doručení, kotva)
  final inflight = <(double, BroadcastAnchor)>[];
  var nextAnchor = 0.0;
  var lastDelivery = 0.0;
  var outageUntil = -1.0;

  final errs = <(double, double)>[];
  final seekTimes = <double>[];
  var rateChangesSteady = 0;
  var lastRate = 1.0;
  double? settledAt;

  for (var t = 0.0; t < total; t += dt) {
    // --- vysílač posílá kotvu (heartbeat 10 s), medián 5 čtení ~ šum 4 ms
    if (t >= nextAnchor) {
      nextAnchor += 10000;
      final pos = bPos(t) + _gauss(rnd) * 4;
      final anchor = BroadcastAnchor(recordingId: 'x', index: 0, positionMs: pos, atServerMs: t + clockErrB, isPlaying: true, epoch: 1);
      var delay = 20 + rnd.nextDouble() * 60;
      if (burstyNet && rnd.nextDouble() < 0.1) delay += rnd.nextDouble() * 2000; // head-of-line shluk
      // Výpadek spojení (po připojení -- bez první kotvy posluchač nehraje).
      if (burstyNet && t > 20000 && rnd.nextDouble() < 0.03) outageUntil = t + 20000 + rnd.nextDouble() * 40000;
      // TCP: v jednom spojení nic nepředběhne předchozí zprávu.
      final at = math.max(t + delay, lastDelivery);
      lastDelivery = at;
      if (t >= outageUntil) inflight.add((at, anchor));
    }
    while (inflight.isNotEmpty && inflight.first.$1 <= t) {
      model.apply(inflight.removeAt(0).$2);
    }

    // --- skutečný zvuk posluchače
    if (pendingRate != null && t >= pendingRateAt) {
      lRate = pendingRate;
      pendingRate = null;
    }
    if (t < silentUntil) {
      // po seeku: zvuk ještě nehraje, pozice stojí na cíli
    } else {
      if (reportedOverride) {
        lPos = silentTarget;
        reportedOverride = false;
      }
      lPos += dt * lRate * dacL;
    }

    // --- měření a regulace každých 250 ms
    if (t % 250 < dt && model.anchor != null) {
      // Systémové hodiny posluchače driftují (sysL), ale posun se měří znovu
      // každých 15 s -- zbývá jen chyba odhadu posunu.
      final serverNowEst = t + clockErrL + (sysL - 1) * (t % 15000);
      final target = targetAt(model.anchor!, serverNowEst).positionMs;
      // Hlášená pozice: po seeku just_audio hlásí cíl hned, i když je ticho.
      final reported = (t < silentUntil ? silentTarget : lPos) + _gauss(rnd) * 8;
      final action = reg.observe(nowMs: t, errorMs: reported - target);
      if (action.kind == SyncActionKind.seek) {
        seekTimes.add(t);
        silentUntil = t + 120 + _gauss(rnd).abs() * 40;
        silentTarget = target + action.leadMs;
        reportedOverride = true;
      } else if (action.kind == SyncActionKind.setRate) {
        pendingRate = action.rate;
        pendingRateAt = t + 100; // platforma použije rychlost o chvilku později
        if (t > 30000 && action.rate != lastRate) rateChangesSteady++;
        lastRate = action.rate!;
      }
    }

    final trueErr = (t < silentUntil ? double.nan : lPos - bPos(t));
    if (t % 100 < dt) errs.add((t, trueErr.isNaN ? 1e9 : trueErr));
    if (settledAt == null && !trueErr.isNaN && trueErr.abs() < 40 && t > 0) settledAt = t;
  }

  final steady = errs.where((e) => e.$1 >= 10000).map((e) => e.$2.abs()).toList()..sort();
  final p95 = steady[(steady.length * 0.95).floor()];
  var maxIn3 = 0;
  for (var i = 0; i < seekTimes.length; i++) {
    final n = seekTimes.where((s) => s >= seekTimes[i] && s < seekTimes[i] + 3000).length;
    maxIn3 = math.max(maxIn3, n);
  }
  final steadyMinutes = (total - 30000) / 60000;
  return _SimResult(p95, maxIn3, rateChangesSteady / steadyMinutes, settledAt ?? double.infinity, errs);
}
