// Ladička -- most mezi mikrofonem (Web Audio) a Dartem. Načítá se až při
// otevření ladičky (tuner_bridge_web.dart), ne při startu appky.
// Zvuk se zpracovává jen v zařízení (tuner-worklet.js); nic se neodesílá.
(function () {
  let ctx = null;
  let stream = null;
  let node = null;
  let sink = null;
  let muteUntil = 0;
  let toneCtx = null;

  function setSession(type) {
    try {
      if (navigator.audioSession) navigator.audioSession.type = type;
    } catch (_) {}
  }

  async function start(onData, onStateChange) {
    await stop();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      throw new Error('unsupported');
    }
    // Zapnuté potlačení ozvěny / šumu / automatický zisk by na iOS tlumily
    // basovou E a "pumpovaly" hlasitost -- ručička by skákala.
    setSession('auto');
    stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: 1,
      },
      video: false,
    });
    // AudioContext až po otevření mikrofonu (starší iOS jinak převzorkovává
    // s chybami).
    const Ctx = window.AudioContext || window.webkitAudioContext;
    ctx = new Ctx({ latencyHint: 'interactive' });
    await ctx.audioWorklet.addModule('tuner/tuner-worklet.js');
    const source = ctx.createMediaStreamSource(stream);
    node = new AudioWorkletNode(ctx, 'opentify-tuner', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
    node.port.onmessage = (e) => {
      if (ctx && ctx.currentTime < muteUntil) return; // vlastní referenční tón
      const r = e.data;
      onData(r.hz, r.clarity, r.rms);
    };
    // Tichý výstup -- některé prohlížeče jinak nepřipojený uzel nezpracují.
    sink = ctx.createGain();
    sink.gain.value = 0;
    source.connect(node);
    node.connect(sink);
    sink.connect(ctx.destination);
    ctx.onstatechange = () => {
      if (onStateChange) onStateChange(ctx ? ctx.state : 'closed');
    };
    if (ctx.state !== 'running') await ctx.resume();
    const track = stream.getAudioTracks()[0];
    const settings = track && track.getSettings ? track.getSettings() : {};
    return JSON.stringify({
      sampleRate: ctx.sampleRate,
      echoCancellation: settings.echoCancellation,
      noiseSuppression: settings.noiseSuppression,
      autoGainControl: settings.autoGainControl,
      label: track ? track.label : '',
    });
  }

  async function stop() {
    if (node) {
      node.port.onmessage = null;
      try { node.disconnect(); } catch (_) {}
      node = null;
    }
    if (sink) {
      try { sink.disconnect(); } catch (_) {}
      sink = null;
    }
    if (stream) {
      stream.getTracks().forEach((t) => t.stop());
      stream = null;
    }
    if (ctx) {
      const c = ctx;
      ctx = null;
      c.onstatechange = null;
      try { await c.close(); } catch (_) {}
    }
    // Uvolněný mikrofon -> iOS vrátí zvukovou relaci na přehrávání (hudba
    // jinak mohla hrát potichu ze sluchátka).
    setSession('auto');
  }

  // Referenční tón struny: "drnknutí" (harmonické + doznění) přes Web Audio.
  // Mikrofon během něj ignoruje vlastní zvuk.
  function playTone(hz, seconds) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    const c = ctx || toneCtx || (toneCtx = new Ctx());
    if (c.state !== 'running') c.resume();
    const now = c.currentTime;
    const osc = c.createOscillator();
    const real = new Float32Array([0, 1, 0.55, 0.3, 0.18, 0.1, 0.06]);
    const imag = new Float32Array(real.length);
    osc.setPeriodicWave(c.createPeriodicWave(real, imag));
    osc.frequency.value = hz;
    const gain = c.createGain();
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(0.35, now + 0.012);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + seconds);
    osc.connect(gain);
    gain.connect(c.destination);
    osc.start(now);
    osc.stop(now + seconds + 0.05);
    if (ctx) muteUntil = ctx.currentTime + seconds + 0.25;
  }

  window.opentifyTuner = { start, stop, playTone };
})();
