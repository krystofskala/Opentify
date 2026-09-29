// node test/tuner/worklet_test.js -- ověří detektor ladičky na syntetických
// signálech (čisté tóny, "kytara" se slabou základní frekvencí, šum, 44.1 i
// 48 kHz). Bez závislostí.
const { TunerProcessor } = require('../../web/tuner/tuner-worklet.js');

function cents(a, b) { return 1200 * Math.log2(a / b); }

function render(sr, seconds, gen) {
  const out = new Float32Array(Math.floor(sr * seconds));
  for (let i = 0; i < out.length; i++) out[i] = gen(i / sr);
  return out;
}

function detect(sr, signal) {
  const p = new TunerProcessor(sr);
  const results = [];
  for (let i = 0; i < signal.length; i += 128) results.push(...p.feed(signal.subarray(i, i + 128)));
  // Po náběhu (bez prvních 150 ms), jen jasné odhady.
  const settled = results.slice(Math.ceil(0.15 / (256 * p.factor / sr))).filter((r) => r.clarity > 0.85);
  if (settled.length === 0) return { hz: 0, spread: Infinity, n: 0 };
  const hz = settled.map((r) => r.hz).sort((a, b) => a - b);
  const median = hz[Math.floor(hz.length / 2)];
  const spread = Math.max(...hz.map((h) => Math.abs(cents(h, median))));
  return { hz: median, spread, n: settled.length };
}

let rnd = 12345;
function noise() { rnd = (rnd * 1103515245 + 12345) & 0x7fffffff; return rnd / 0x7fffffff * 2 - 1; }

const guitar = (f0, amp = 0.3) => (t) => {
  const env = Math.exp(-t * 1.2);
  const hs = [0.35, 1.0, 0.7, 0.45, 0.25, 0.15]; // 2. harmonická silnější než základní
  let s = 0;
  hs.forEach((a, k) => {
    const n = k + 1;
    const fn = n * f0 * Math.sqrt(1 + 0.00012 * n * n); // mírná inharmonicita struny
    s += a * Math.sin(2 * Math.PI * fn * t + k);
  });
  return amp * env * s / 2 + 0.01 * noise();
};
const sine = (f) => (t) => 0.2 * Math.sin(2 * Math.PI * f * t) + 0.003 * noise();

const cases = [];
for (const sr of [48000, 44100]) {
  for (const f of [73.42, 82.41, 110, 146.83, 196, 246.94, 329.63, 659.26, 1318.5]) {
    for (const off of [0, 5, -20]) {
      const hz = f * Math.pow(2, off / 1200);
      cases.push({ name: `sine ${hz.toFixed(2)} Hz @${sr}`, sr, hz, sig: render(sr, 1.0, sine(hz)), tol: 0.5 });
    }
  }
  for (const f of [73.42, 82.41, 110, 146.83, 196, 246.94, 329.63]) {
    cases.push({ name: `guitar ${f} Hz @${sr}`, sr, hz: f, sig: render(sr, 1.5, guitar(f)), tol: 2.5 });
  }
}

let failed = 0;
for (const c of cases) {
  const r = detect(c.sr, c.sig);
  const err = r.hz ? cents(r.hz, c.hz) : Infinity;
  const ok = Math.abs(err) <= c.tol && r.spread < 3;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${c.name.padEnd(28)} -> ${r.hz.toFixed(3)} Hz  err ${err.toFixed(2)} ¢  spread ${r.spread.toFixed(2)} ¢  n=${r.n}`);
}

// Ticho a šum nesmí dávat jasný tón.
const silent = detect(48000, render(48000, 1, () => 0.002 * noise()));
console.log(`${silent.n === 0 ? 'ok  ' : 'FAIL'} noise only -> ${silent.n} clear readings`);
if (silent.n !== 0) failed++;

// Výkon: ms na jednu analýzu (47× za s).
const p = new TunerProcessor(48000);
const sig = render(48000, 5, guitar(82.41));
const t0 = process.hrtime.bigint();
let count = 0;
for (let i = 0; i < sig.length; i += 128) count += p.feed(sig.subarray(i, i + 128)).length;
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
console.log(`perf: ${(ms / count).toFixed(3)} ms per analysis (${count} analyses)`);

console.log(failed ? `${failed} FAILED` : 'all passed');
process.exit(failed ? 1 : 0);
