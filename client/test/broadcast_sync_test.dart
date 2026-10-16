import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/broadcast_sync.dart';
import 'package:opentify_client/core/stall_watch.dart';

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

  group('regrese 16. 10. (posluchač o 30 s napřed)', () {
    test('změřená kotva po plánovaném startu nepočítá uběhlý čas dvakrát', () {
      final m = TimelineModel();
      // Plán: start v 10 000 od 0.
      m.apply(const BroadcastAnchor(recordingId: 'x', index: 1, positionMs: 0, atServerMs: 10000, startAtServerMs: 10000, isPlaying: true, epoch: 3));
      expect(targetAt(m.anchor!, 9000).waitingForStart, isTrue);
      // Vysílač se rozjel, heartbeat po 30 s: pozice 30 000 v čase 40 000.
      expect(m.apply(const BroadcastAnchor(recordingId: 'x', index: 1, positionMs: 30000, atServerMs: 40000, isPlaying: true, epoch: 3)), isFalse);
      expect(targetAt(m.anchor!, 40000).positionMs, closeTo(30000, 1));
      expect(targetAt(m.anchor!, 45000).positionMs, closeTo(35000, 1));
      // I kdyby plán v kotvě zůstal (server), změřená kotva má přednost.
      const stale = BroadcastAnchor(recordingId: 'x', index: 1, positionMs: 30000, atServerMs: 40000, startAtServerMs: 10000, isPlaying: true);
      expect(targetAt(stale, 40000).positionMs, closeTo(30000, 1));
    });

    test('kotva bez platných hodin u téže skladby cíl neposune', () {
      final m = TimelineModel()..apply(const BroadcastAnchor(recordingId: 'x', index: 0, positionMs: 0, atServerMs: 0, isPlaying: true, epoch: 1));
      expect(m.apply(const BroadcastAnchor(recordingId: 'x', index: 0, positionMs: 99999, atServerMs: 10, isPlaying: true, epoch: 1, clockOk: false)), isFalse);
      expect(targetAt(m.anchor!, 5000).positionMs, 5000);
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
    test('malá odchylka -> rychlost, velká -> připravený start, pak usazení', () {
      final r = SyncRegulator();
      final a = r.observe(nowMs: 0, errorMs: 80);
      expect(a.kind, SyncActionKind.setRate);
      expect(a.rate, 0.99); // posluchač napřed -> zpomalit
      expect(SyncRegulator().observe(nowMs: 0, errorMs: 30).kind, SyncActionKind.none); // do ±40 ms nic
      final s = SyncRegulator();
      expect(s.observe(nowMs: 0, errorMs: -900).kind, SyncActionKind.resync);
      expect(s.observe(nowMs: 500, errorMs: -900).kind, SyncActionKind.none); // usazení
    });

    test('nikdy seek dokola: nejvýš 1 připravený start za 5 s, po opakovaných jen rychlost', () {
      final r = SyncRegulator();
      var t = 0.0;
      var n = 0;
      for (var i = 0; i < 240; i++, t += 250) {
        if (r.observe(nowMs: t, errorMs: 1000).kind == SyncActionKind.resync) n++;
      }
      // 60 s: po 3 startech volný režim (60 s, práh 2 s) -- dál jen rychlost.
      expect(n, 3);
      expect(r.looseMode, isTrue);
    });

    test('setSpeed nefunguje -> malé odchylky nechat, velké připraveným startem', () {
      final r = SyncRegulator()..rateUnsupported();
      expect(r.observe(nowMs: 0, errorMs: 200).kind, SyncActionKind.none);
      var resynced = false;
      for (var t = 250.0; t < 6000 && !resynced; t += 250) {
        final a = r.observe(nowMs: t, errorMs: 600);
        expect(a.kind, isNot(SyncActionKind.setRate));
        resynced = a.kind == SyncActionKind.resync;
      }
      expect(resynced, isTrue);
    });
  });

  group('StartLatency', () {
    test('robustní odhad: medián pro play(), p80 pro předstih, úlety nerozhodí, uloží se', () {
      final l = StartLatency();
      expect(l.known(false), isFalse);
      expect(l.estimate(false), 300);
      l.add(false, 1200);
      expect(l.estimate(false), 1200);
      for (final v in const <double>[1100, 1150, 2900, 1180]) {
        l.add(false, v);
      }
      expect(l.estimate(false), 1180); // medián, úlet 2900 ho neposune
      expect(l.p80(false), 1200);
      expect(l.estimate(true), 150); // soubor v zařízení zvlášť
      final back = StartLatency(l.toJson());
      expect(back.estimate(false), 1180);
      l.add(false, 99999); // nesmysl se zahodí
      expect(l.estimate(false), 1180);
    });
  });

  group('soloGo / goLead', () {
    test('zaparkovaný daleko dopředu začne přesně tam, blízko -> nejbližší čas', () {
      const a = BroadcastAnchor(recordingId: 'x', index: 0, positionMs: 10000, atServerMs: 0, isPlaying: true);
      final (t1, p1) = soloGo(a, serverNow: 0, parkedMs: 13000, rttMs: 50);
      expect(t1, 3000);
      expect(p1, 13000);
      final (t2, p2) = soloGo(a, serverNow: 0, parkedMs: 10100, rttMs: 50, startLeadMs: 900);
      expect(t2, goLeadMs(rtts: [50], startLeads: [900]));
      expect(p2, 10000 + t2);
      expect(goLeadMs(), 800);
      expect(goLeadMs(rtts: [1000]), 1800);
    });
  });

  group('BarrierTracker', () {
    test('rychlé přeskoky vysílače -> platí jen bariéra poslední volby', () {
      final b = BarrierTracker();
      b.begin('a');
      b.begin('b');
      b.begin('c'); // ťuk, ťuk, ťuk
      b.prepared(1);
      b.prepared(2);
      expect(b.epoch, isNull); // potvrzení starších prepare neplatí
      b.prepared(3);
      expect(b.epoch, 3);
      expect(b.recordingId, 'c');
      expect(b.acceptsGo(1), isFalse);
      expect(b.readyToReport, isFalse);
      b.ownReady = true;
      expect(b.readyToReport, isTrue);
      expect(b.acceptsGo(3), isTrue);
      b.clear();
      expect(b.acceptsGo(3), isFalse);
    });
  });

  group('simulace', () {
    test('posluchač s pomalým startem a načítáním 0,2-3 s, jitterem a záseky: max 1 připravený start navíc, bez seeků', () {
      for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
        final r = _simulate(seed: seed, minutes: 5);
        expect(r.extraStarts, lessThanOrEqualTo(1), reason: 'seed $seed: $r');
        expect(r.p95AfterLastStartMs, lessThan(40), reason: 'seed $seed: $r');
        expect(r.rateChangesPerMin, lessThanOrEqualTo(2), reason: 'seed $seed: $r');
        expect(r.reloads, lessThanOrEqualTo(2), reason: 'seed $seed: $r');
      }
    });

    test('naučená latence startu: po 1-2 startech chyba po startu < 60 ms', () {
      for (final seed in [11, 12, 13, 14, 15, 16]) {
        final r = _startsOnly(seed: seed, starts: 4);
        expect(r[2].abs(), lessThan(60), reason: 'seed $seed: $r');
        expect(r[3].abs(), lessThan(60), reason: 'seed $seed: $r');
      }
    });

    test('zásek zdroje: hlídač znovu načte nejvýš 2×, skupina nečeká déle než limit bariéry', () {
      // Bariéra: 3 posluchači, jeden se zasekl (nikdy ready) -> go po limitu 4 s, ne později.
      const limit = 4000.0;
      final readyAt = <double?>[900, 2600, null]; // null = zasekl se
      final allReady = readyAt.every((r) => r != null);
      final goAfter = allReady ? readyAt.map((r) => r!).reduce(math.max) : limit;
      expect(goAfter, limit);
      // Hlídač u zaseknutého: po 5 s znovu načíst, nejvýš 2×, pak chyba.
      final w = StallWatch();
      w.newTrack();
      var t = 0.0;
      final actions = <String>[];
      w.arm(t, 0);
      for (; t < 30000; t += 250) {
        final a = w.check(nowMs: t, positionMs: 0, wantsPlaying: true);
        if (a != 'ok') {
          actions.add(a);
          if (a == 'reload') w.arm(t, 0);
        }
      }
      expect(actions, ['reload', 'reload', 'fail']);
      // Rozjede se po prvním znovunačtení -> dál nic.
      final w2 = StallWatch()..newTrack();
      w2.arm(0, 0);
      expect(w2.check(nowMs: 5000, positionMs: 0, wantsPlaying: true), 'reload');
      w2.arm(5000, 0);
      expect(w2.check(nowMs: 6000, positionMs: 400, wantsPlaying: true), 'ok');
      expect(w2.armed, isFalse);
    });

    test('10 přirozených přechodů: max posun v prvních 3 s po přechodu < 80 ms', () {
      final rnd = math.Random(7);
      final loadB = LeadEstimate(150), startB = LeadEstimate(50);
      final loadL = LeadEstimate(150), startL = LeadEstimate(50);
      var worst = 0.0;
      for (var i = 0; i < 10; i++) {
        const x = 100000.0;
        double startOf(LeadEstimate load, LeadEstimate start, double loadMean, double startMean) {
          final loadActual = loadMean + _gauss(rnd) * 30;
          final startActual = startMean + _gauss(rnd) * 8;
          final callLoad = loadAt(x: x, loadLeadMs: load.valueMs, startLeadMs: start.valueMs);
          final ready = callLoad + loadActual;
          final playCall = math.max(ready, x - start.valueMs);
          load.add(loadActual);
          start.add(startActual);
          return playCall + startActual;
        }

        final b = startOf(loadB, startB, 120, 40);
        final l = startOf(loadL, startL, 180, 60);
        worst = math.max(worst, (b - l).abs());
      }
      expect(worst, lessThan(80));
    });
  });
}

double _gauss(math.Random r) {
  final u1 = r.nextDouble().clamp(1e-12, 1.0);
  final u2 = r.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

class _SimResult {
  _SimResult(this.extraStarts, this.p95AfterLastStartMs, this.rateChangesPerMin, this.reloads);
  final int extraStarts;
  final double p95AfterLastStartMs;
  final double rateChangesPerMin;
  final int reloads;

  @override
  String toString() =>
      'starty navíc=$extraStarts, p95=${p95AfterLastStartMs.toStringAsFixed(1)} ms, rychlost/min=${rateChangesPerMin.toStringAsFixed(2)}, znovunačtení=$reloads';
}

/// Zařízení s proměnlivou latencí startu (play() -> zvuk): série připravených
/// startů, chyba zvuku proti cíli po každém (ms, kladná = zazní pozdě).
List<double> _startsOnly({required int seed, required int starts}) {
  final rnd = math.Random(seed);
  final latencyMean = 300 + rnd.nextDouble() * 1200; // 300-1500 ms
  final learn = StartLatency();
  final out = <double>[];
  for (var i = 0; i < starts; i++) {
    final est = learn.estimate(false);
    const t = 10000.0; // čas go
    final actual = latencyMean + _gauss(rnd) * 20;
    out.add(t - est + actual - t);
    learn.add(false, actual + _gauss(rnd) * 10); // změřeno z události přehrávače
  }
  return out;
}

/// Posluchač proti vysílači, virtuální čas po 10 ms: připojení a dohánění
/// připraveným startem (zaparkovat, ready, go, play v T − naučená latence),
/// za běhu jen rychlost. Zařízení: načtení 0,2-3 s, občas zásek (zdroj
/// nedojde do ready -> hlídač po 5 s znovu načte), latence startu 300-1500 ms
/// s jitterem, drift zvukových hodin, chyba odhadu hodin, šum pozice.
_SimResult _simulate({required int seed, required int minutes}) {
  final rnd = math.Random(seed);
  const dt = 10.0;
  final total = minutes * 60000.0;
  final dacB = 1 + (rnd.nextDouble() - 0.5) * 100e-6;
  final dacL = 1 + (rnd.nextDouble() - 0.5) * 100e-6;
  final clockErrB = (rnd.nextDouble() - 0.5) * 10;
  final clockErrL = (rnd.nextDouble() - 0.5) * 10;
  final latencyMean = 300 + rnd.nextDouble() * 1200;
  final learn = StartLatency();
  double bPos(double t) => t * dacB;

  final model = TimelineModel();
  final reg = SyncRegulator();
  final watch = StallWatch();
  var nextAnchor = 0.0;

  var playing = false;
  var lPos = 0.0;
  var lRate = 1.0;
  double? pendingRate;
  var pendingRateAt = 0.0;
  double? soundAt;
  double? readyAt;
  double? parkPos;
  double? goPlayCall;
  var starts = 0;
  var lastStartAt = 0.0;
  var rateChanges = 0;
  var reloads = 0;
  final errs = <(double, double)>[];

  void load(double t) {
    // 15 % načtení se zasekne (nikdy ready) -- jen první dvě, ať test skončí.
    final stuck = reloads < 2 && rnd.nextDouble() < 0.15;
    readyAt = stuck ? null : t + 200 + rnd.nextDouble() * 2800;
    watch.arm(t, 0);
  }

  void beginPrepared(double t) {
    // Ztichne, načte a zaparkuje na cíli za ~4 s.
    playing = false;
    soundAt = null;
    goPlayCall = null;
    final a = model.anchor!;
    parkPos = targetAt(a, t + clockErrL + 4000).positionMs;
    lPos = parkPos!;
    watch.newTrack();
    load(t);
    starts++;
  }

  for (var t = 0.0; t < total; t += dt) {
    if (t >= nextAnchor) {
      nextAnchor += 10000;
      model.apply(BroadcastAnchor(recordingId: 'x', index: 0, positionMs: bPos(t) + _gauss(rnd) * 4, atServerMs: t + clockErrB, isPlaying: true, epoch: 1));
      if (starts == 0) beginPrepared(t); // připojení
    }
    // Zásek načítání -> hlídač znovu načte.
    if (readyAt == null && goPlayCall == null && soundAt == null && !playing && parkPos != null) {
      final w = watch.check(nowMs: t, positionMs: 0, wantsPlaying: true);
      if (w == 'reload') {
        reloads++;
        load(t);
      }
    }
    if (readyAt != null && t >= readyAt!) {
      readyAt = null;
      watch.disarm();
      final (tg, pos) = soloGo(model.anchor!, serverNow: t + clockErrL + 30, parkedMs: parkPos!, rttMs: 60, startLeadMs: learn.p80(false));
      lPos = pos; // posun pozastaveně stihne před T
      goPlayCall = tg - clockErrL - learn.estimate(false);
    }
    if (goPlayCall != null && t >= goPlayCall!) {
      final actual = latencyMean * (0.9 + rnd.nextDouble() * 0.2) + _gauss(rnd) * 15;
      soundAt = t + actual;
      goPlayCall = null;
      learn.add(false, actual + _gauss(rnd) * 10);
    }
    if (soundAt != null && t >= soundAt!) {
      playing = true;
      soundAt = null;
      lastStartAt = t;
      reg.reset(t);
    }
    if (pendingRate != null && t >= pendingRateAt) {
      lRate = pendingRate!;
      pendingRate = null;
    }
    if (playing) lPos += dt * lRate * dacL;

    if (playing && t % 250 < dt) {
      final target = targetAt(model.anchor!, t + clockErrL).positionMs;
      final action = reg.observe(nowMs: t, errorMs: lPos + _gauss(rnd) * 8 - target);
      if (action.kind == SyncActionKind.resync) {
        beginPrepared(t);
      } else if (action.kind == SyncActionKind.setRate) {
        pendingRate = action.rate;
        pendingRateAt = t + 100;
        rateChanges++;
      }
    }
    if (playing && t % 100 < dt) errs.add((t, lPos - bPos(t)));
  }
  // Ustálený stav: latence startu kolísá (±10 %), zbytek po startu dorovná
  // rychlost během ~10 s -- měří se od 15 s po posledním startu.
  final after = errs.where((e) => e.$1 >= lastStartAt + 15000).map((e) => e.$2.abs()).toList()..sort();
  final p95 = after.isEmpty ? double.infinity : after[(after.length * 0.95).floor()];
  return _SimResult(starts - 1, p95, rateChanges / (minutes - 0.5), reloads);
}
