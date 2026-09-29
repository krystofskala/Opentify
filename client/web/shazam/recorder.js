// Open Shazam -- nahrávání z mikrofonu (MediaRecorder). Načítá se až při
// otevření obrazovky. Nahrávka jde jen na vlastní server (/api/v1/recognize),
// ten z ní spočítá otisk a přes VPN se zeptá Shazamu; zvuk se nikam neukládá.
(function () {
  let stream = null;
  let recorder = null;
  let chunks = [];
  let mime = '';

  function setSession(type) {
    try { if (navigator.audioSession) navigator.audioSession.type = type; } catch (_) {}
  }

  function pickMime() {
    const options = ['audio/mp4', 'audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus'];
    for (const m of options) {
      if (window.MediaRecorder && MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(m)) return m;
    }
    return '';
  }

  async function start() {
    await stop();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
      throw new Error('unsupported');
    }
    setSession('auto');
    // Hudba z reproduktoru: potlačení ozvěny/šumu by ji "vyčistilo" pryč.
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 },
      video: false,
    });
    mime = pickMime();
    chunks = [];
    recorder = new MediaRecorder(stream, mime ? { mimeType: mime, audioBitsPerSecond: 96000 } : undefined);
    mime = recorder.mimeType || mime;
    recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
    recorder.start(500);
    return mime;
  }

  // Vše nahrané od začátku (prefix nahrávky je platný soubor -- první kus
  // nese hlavičku), aby šlo zkoušet rozpoznat průběžně.
  async function snapshot() {
    if (recorder && recorder.state === 'recording') {
      await new Promise((resolve) => {
        const done = () => { recorder.removeEventListener('dataavailable', done); resolve(); };
        recorder.addEventListener('dataavailable', done);
        recorder.requestData();
      });
    }
    const blob = new Blob(chunks, { type: mime || 'application/octet-stream' });
    return new Uint8Array(await blob.arrayBuffer());
  }

  async function stop() {
    if (recorder) {
      try { if (recorder.state !== 'inactive') recorder.stop(); } catch (_) {}
      recorder.ondataavailable = null;
      recorder = null;
    }
    if (stream) {
      stream.getTracks().forEach((t) => t.stop());
      stream = null;
    }
    chunks = [];
    setSession('auto');
  }

  function mimeType() { return mime; }

  window.opentifyRecorder = { start, snapshot, stop, mimeType };
})();
