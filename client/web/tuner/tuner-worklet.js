// Ladička: detekce výšky tónu na zvukovém vlákně (AudioWorklet), mimo
// hlavní vlákno Flutteru. Nic se neodesílá mimo zařízení -- výsledky jdou
// jen přes `port` do stránky.
//
// Postup: dolní propust (2× biquad) -> decimace na ~12 kHz -> kruhový
// buffer 1024 vzorků (~85 ms, víc než 3 periody i u D2 73 Hz) -> každých
// 256 vzorků (~21 ms) McLeod Pitch Method (NSDF, "první klíčové maximum nad
// k·nejvyšším") s parabolickou interpolací. Posílá {hz, clarity, rms};
// hradlování, vyhlazení a výběr struny dělá Dart (tuner_logic.dart).
// Viz docs/GUITAR_TUNER_RESEARCH.md.

const WINDOW = 1024;
const HOP = 256;
const MIN_HZ = 60;
const MAX_HZ = 1400;
const MPM_K = 0.9;

// Biquad dolní propust (RBJ cookbook).
function lowpass(sampleRate, fc, q) {
  const w0 = (2 * Math.PI * fc) / sampleRate;
  const alpha = Math.sin(w0) / (2 * q);
  const cos = Math.cos(w0);
  const a0 = 1 + alpha;
  return {
    b0: (1 - cos) / 2 / a0,
    b1: (1 - cos) / a0,
    b2: (1 - cos) / 2 / a0,
    a1: (-2 * cos) / a0,
    a2: (1 - alpha) / a0,
    x1: 0, x2: 0, y1: 0, y2: 0,
  };
}

function biquad(f, x) {
  const y = f.b0 * x + f.b1 * f.x1 + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2;
  f.x2 = f.x1; f.x1 = x;
  f.y2 = f.y1; f.y1 = y;
  return y;
}

// McLeod Pitch Method nad `x` (délka WINDOW) se vzorkovací frekvencí `sr`.
// Vrací [hz, clarity] nebo [0, 0].
function mpm(x, sr, nsdf) {
  const n = x.length;
  const maxTau = Math.min(n - 1, Math.ceil(sr / MIN_HZ));
  const minTau = Math.max(2, Math.floor(sr / MAX_HZ));
  let m = 0;
  for (let i = 0; i < n; i++) m += 2 * x[i] * x[i];
  if (m <= 1e-12) return [0, 0];
  for (let tau = 0; tau <= maxTau; tau++) {
    if (tau > 0) m -= x[tau - 1] * x[tau - 1] + x[n - tau] * x[n - tau];
    let r = 0;
    for (let i = 0; i < n - tau; i++) r += x[i] * x[i + tau];
    nsdf[tau] = m > 1e-12 ? (2 * r) / m : 0;
  }
  // Klíčová maxima: nejvyšší bod v každém kladném úseku mezi průchody nulou.
  const peaks = [];
  let tau = 1;
  while (tau < maxTau && nsdf[tau] > 0) tau++; // přeskočit úsek kolem τ=0
  while (tau < maxTau) {
    while (tau < maxTau && nsdf[tau] <= 0) tau++;
    let best = -1;
    while (tau < maxTau && nsdf[tau] > 0) {
      if (best < 0 || nsdf[tau] > nsdf[best]) best = tau;
      tau++;
    }
    if (best > 0 && best >= minTau) peaks.push(best);
  }
  if (peaks.length === 0) return [0, 0];
  let highest = 0;
  for (const p of peaks) highest = Math.max(highest, nsdf[p]);
  const threshold = MPM_K * highest;
  const chosen = peaks.find((p) => nsdf[p] >= threshold);
  // Parabolická interpolace vrcholu.
  const a = nsdf[chosen - 1], b = nsdf[chosen], c = nsdf[chosen + 1];
  const denom = a - 2 * b + c;
  const shift = denom !== 0 ? (0.5 * (a - c)) / denom : 0;
  let period = chosen + shift;
  const clarity = b - 0.25 * (a - c) * shift;
  // Krátká perioda (vysoké tóny, pár vzorků) -> interpolace na desetiny
  // vzorku je znát v centech. Změří se vrchol u násobku periody (m·τ) a
  // vydělí m -- chyba interpolace se tím zmenší m-krát.
  const mult = Math.floor((maxTau - 2) / period);
  if (mult >= 2) {
    const center = Math.round(mult * period);
    let best = center;
    for (let t = center - 2; t <= center + 2; t++) {
      if (t > 0 && t < maxTau && nsdf[t] > nsdf[best]) best = t;
    }
    const a2 = nsdf[best - 1], b2 = nsdf[best], c2 = nsdf[best + 1];
    const d2 = a2 - 2 * b2 + c2;
    if (b2 > 0.5 * clarity && d2 < 0) period = (best + (0.5 * (a2 - c2)) / d2) / mult;
  }
  return [sr / period, Math.min(1, clarity)];
}

class TunerProcessor extends (typeof AudioWorkletProcessor !== 'undefined' ? AudioWorkletProcessor : Object) {
  constructor(sr) {
    super();
    const rate = typeof sampleRate !== 'undefined' ? sampleRate : sr;
    this.factor = Math.max(1, Math.round(rate / 12000));
    this.rate = rate / this.factor;
    const fc = Math.min(2600, this.rate * 0.4);
    this.f1 = lowpass(rate, fc, 0.54);
    this.f2 = lowpass(rate, fc, 1.31);
    this.phase = 0;
    this.ring = new Float32Array(WINDOW);
    this.write = 0;
    this.filled = 0;
    this.sinceHop = 0;
    this.frame = new Float32Array(WINDOW);
    this.nsdf = new Float32Array(WINDOW);
  }

  // Zpracuje jeden blok vzorků; vrátí pole výsledků (kvůli testům mimo worklet).
  feed(input) {
    const out = [];
    for (let i = 0; i < input.length; i++) {
      const y = biquad(this.f2, biquad(this.f1, input[i]));
      if (++this.phase < this.factor) continue;
      this.phase = 0;
      this.ring[this.write] = y;
      this.write = (this.write + 1) % WINDOW;
      if (this.filled < WINDOW) this.filled++;
      if (++this.sinceHop >= HOP && this.filled === WINDOW) {
        this.sinceHop = 0;
        out.push(this.analyse());
      }
    }
    return out;
  }

  analyse() {
    const f = this.frame;
    let mean = 0;
    for (let i = 0; i < WINDOW; i++) {
      f[i] = this.ring[(this.write + i) % WINDOW];
      mean += f[i];
    }
    mean /= WINDOW;
    let energy = 0;
    for (let i = 0; i < WINDOW; i++) {
      f[i] -= mean;
      energy += f[i] * f[i];
    }
    const rms = Math.sqrt(energy / WINDOW);
    if (rms < 1e-4) return { hz: 0, clarity: 0, rms };
    const [hz, clarity] = mpm(f, this.rate, this.nsdf);
    return { hz, clarity, rms };
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel) {
      for (const r of this.feed(channel)) this.port.postMessage(r);
    }
    return true;
  }
}

if (typeof registerProcessor !== 'undefined') {
  registerProcessor('opentify-tuner', TunerProcessor);
} else if (typeof module !== 'undefined') {
  module.exports = { TunerProcessor, mpm };
}
