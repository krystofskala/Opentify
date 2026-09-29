# Guitar tuner – research notes

Status: research only (2026-09-29). Goal: a GuitarTuna-grade tuner inside Opentify,
100 % on-device (no network, no tracking, no ads). Target: iPhone Safari home-screen PWA
first, desktop Chrome second, native iOS app later (see `IOS_NATIVE_PLAN.md`).

**TL;DR / recommendation:** capture the mic with `getUserMedia` (all processing off),
run an **AudioWorklet** that ring-buffers samples and does **McLeod Pitch Method (MPM)**
on a decimated signal, post `{hz, clarity, rms}` ~20–30×/s to Dart via `dart:js_interop`,
and do note mapping, string detection and smoothing in Dart. Write the MPM ourselves
(~150 lines, or vendor `pitchy`, 0BSD/MIT). Pause music while the tuner is open and fully
release the mic when leaving. Same Dart logic ports 1:1 to the native app later
(AVAudioEngine tap → same algorithm).

---

## 1. Mic input in an iOS standalone PWA

| Topic | Finding | Impact for us |
|---|---|---|
| Availability | `getUserMedia` works in home-screen PWAs since iOS 13.4; AudioWorklet since Safari 14.5. Requires HTTPS (we have Tailscale HTTPS). | OK. |
| Permission persistence | Standalone PWAs **do not remember** the mic grant across launches – the prompt comes back after every cold start (and often after reload). Long-standing, still reported in 2025–26. | Accept it: one prompt per tuner session. Show a Czech pre-prompt explaining why. |
| Hash-change bug | In standalone mode iOS **revokes the capture permission whenever the URL hash changes** ([WebKit 215884](https://bugs.webkit.org/show_bug.cgi?id=215884)). | **Opentify uses Flutter's default hash URL strategy** (no `usePathUrlStrategy` in `client/`). Any `go_router` navigation while the mic is open can kill it or re-prompt. Keep the tuner on one route, don't navigate while live; stop the stream on leave and restart on return. Switching to path strategy would help but needs server rewrites – separate decision. |
| Must be in a user gesture | `AudioContext.resume()` and ideally `getUserMedia` must be called from a tap. iOS also suspends contexts after interruptions (call, Siri, backgrounding). | "Spustit ladičku" button; listen to `statechange` and show a "tap to resume" state. |
| Processing flags | Request `{echoCancellation:false, noiseSuppression:false, autoGainControl:false, channelCount:1}`. WebKit honours `echoCancellation:false` since 2019 ([WebKit 179411](https://bugs.webkit.org/show_bug.cgi?id=179411)); on iOS the voice-processing unit (EC + AGC + NS + band-limiting) is tied to EC, so turning EC off is the key one. Older Safari ignored NS/AGC ([addpipe](https://blog.addpipe.com/getusermedia-audio-constraints/)). | Verify at runtime with `track.getSettings()`; log it in a debug overlay. With EC on, the low E fundamental is attenuated and AGC pumps the level → unstable needle. |
| Sample rate | iPhone hardware is normally 48 kHz (44.1 kHz on some routes/headsets). Can't force it via constraints. | Never hardcode – always use `audioContext.sampleRate`. Create the AudioContext **after** the mic is open to avoid rate-mismatch resampling glitches seen on older iOS. |
| Audio session / music | Opening the mic flips WebKit's inferred AVAudioSession to **play-and-record without defaultToSpeaker**: media playback can drop to the **earpiece at low volume**, and headphone output can jump to the speaker ([write-up](https://samueleddy.com/writing/ios-safari-audio-sessions/), [WebKit 230902](https://bugs.webkit.org/show_bug.cgi?id=230902), [route switch report](https://medium.com/@python-javascript-php-html-css/ios-safari-forces-audio-output-to-speakers-when-using-getusermedia-2615196be6fe)). Releasing all tracks flips it back to playback. `navigator.audioSession.type` (Safari 17+, [MDN](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/audioSession), [W3C explainer](https://github.com/w3c/audio-session/blob/main/explainer.md)) lets us state intent; WebKit only allows audio capture when it is `auto` or `play-and-record`. | **Pause just_audio when the tuner opens** (a tuner shouldn't compete with music anyway; also prevents the music being "heard" by the tuner). On leave: `track.stop()` on every track, `ctx.close()`, set `audioSession.type='playback'` if supported, then allow resume. Reference tones: play through Web Audio (`AudioContext.destination` stays on the speaker even in play-and-record), not through just_audio. |
| Regressions | iOS betas occasionally break mic capture entirely (e.g. [iOS 26.1 beta 1](https://developer.apple.com/forums/thread/802555), fixed in beta 2). | Graceful error UI ("Mikrofon není dostupný") + no crash. |
| Backgrounding | PWAs can't capture in background. | Stop on `visibilitychange: hidden`, restart on visible. |

Desktop Chrome: straightforward; all three flags honoured, sample rate usually 48 kHz.

## 2. Pitch detection for guitar

**Requirements.** Range E2 82.4 Hz (drop D: D2 73.4 Hz) to ~E6 1.3 kHz for chromatic.
1 cent at 82 Hz = 0.048 Hz, so raw FFT bin resolution (48 kHz / 4096 = 11.7 Hz) is useless
without heavy interpolation → **time-domain period estimation** (autocorrelation family)
with parabolic peak interpolation is the right tool.

| Method | Pros | Cons |
|---|---|---|
| Plain FFT peak | Cheap | Picks harmonics (guitar 2nd/3rd harmonic often stronger than fundamental on low strings); poor low-f resolution. |
| Plain autocorrelation | Simple | Octave errors, level dependent. |
| **YIN** (de Cheveigné & Kawahara 2002) | Accurate, well-known threshold rule for "first dip" → few octave-down errors | Slightly more tuning of threshold; O(N·W) unless FFT-based. |
| **MPM / NSDF** (McLeod & Wyvill 2005, [thesis](https://www.cs.otago.ac.nz/research/publications/oucs-2008-03.pdf)) | Normalised → level-independent; "first key max above k·highest max" rule handles octaves well; gives a **clarity** 0–1 for gating; good at low frequencies | Needs ≥ 2 periods in window. |

**Choice: MPM** (YIN as a fallback candidate – both are ~equal in accuracy on clean guitar
signals; MPM's clarity value is convenient for gating/UI).

**Window.** Need ≥ 2–3 periods of the lowest note: 73 Hz → 13.6 ms/period → ~41 ms for 3.
- Decimate 48 kHz → 12 kHz (factor 4, after a low-pass ~1.5–2 kHz) and use **1024-sample
  window (85 ms)** – equivalent to 4096 @ 48 kHz at 1/16 of the NSDF cost.
- Hop 256 @ 12 kHz (~21 ms) → ~47 estimates/s, UI updates at display rate.
- Parabolic interpolation of the NSDF peak; for sub-cent precision optionally refine
  by measuring the peak at a multiple of the period (k·τ) as done in some tuners.

**Stability tricks (what GuitarTuna-class tuners do, observable behaviour):**
1. **Gate** on RMS (noise floor calibrated during the first ~0.5 s) and MPM clarity (> ~0.9).
2. **Skip the attack** (~50–100 ms after onset: pick transient is inharmonic and sharp).
3. **Median filter** over the last 5–7 estimates (kills single octave jumps), then
   **exponential smoothing in cents** (τ ≈ 100–150 ms) for the needle; spring/critically
   damped animation in Flutter for rendering.
4. **Octave guard:** if a new estimate is ~×2 or ×½ the running value with lower clarity,
   reject it; in guided mode, prefer the candidate closest to the expected string.
5. **Hold** the last reading ~1 s after the note decays, then fade out (no needle jitter).
6. **"In tune" hysteresis:** green when |cents| < 3 for ≥ 300 ms; leaves green at > 5.
   Display integer cents; ±1 cent display is realistic, true accuracy ±1–2 cents on a
   decaying string (strings themselves drift ~1–3 cents sharp right after the pluck).

**String auto-detection:** map Hz → nearest string of the selected tuning in cents
(`1200·log2(f/f_string)`), with hysteresis so the selection doesn't flicker between
adjacent strings; if distance > ~±350 cents from any string, show the chromatic note.

## 3. Implementation options

| Option | Verdict |
|---|---|
| **(a) AudioWorklet (JS) + `dart:js_interop`** | **Recommended.** Detection runs on the real-time audio thread, off the Flutter/CanvasKit main thread (which on iPhone is busy rendering glass/blur). Worklet posts small messages via `port.postMessage`; Dart receives them with `package:web` (already a dependency; pattern exists in `core/*_web.dart`). Ship worklet as a static JS file in `client/web/`. |
| (b) Dart on raw PCM | Getting PCM into Dart still needs a worklet/ScriptProcessor bridge and copies of Float32Arrays across JS↔Wasm/JS at 48 kHz; runs on the UI thread → jank competes with the needle animation. Only advantage: shared code with native. Not worth it for web. |
| (c) Libraries | **[pitchy](https://github.com/ianprime0509/pitchy)** – MPM, returns `[hz, clarity]`, pure ESM, license 0BSD (repo) / MIT (npm 4.1.0), last release Jan 2024 – small and stable; fine to vendor one file. **[pitchfinder](https://github.com/peterkhayes/pitchfinder)** – YIN/MPM/AMDF, npm 2.3.4 (Dec 2025) is **GPL-3.0** → avoid (copyleft). **[aubiojs](https://github.com/qiuxiang/aubiojs)** – WASM build of aubio, **GPL**, npm last published ~4 years ago → avoid. Writing MPM ourselves is ~150 lines and avoids any bundler (we have none for JS). |
| (d) Native iOS later | `AVAudioEngine` input tap, `AVAudioSession` category `.playAndRecord` with `.measurement` mode (disables voice processing/AGC) + `.defaultToSpeaker`, `.mixWithOthers` if wanted. Port the same MPM (Swift/Accelerate vDSP for FFT-NSDF) or reuse the Dart logic via a Flutter plugin that streams Float32 frames. Needs `NSMicrophoneUsageDescription` in Info.plist. Permission then persists properly (solves the PWA re-prompt). |

**CPU cost on iPhone.** NSDF via FFT: 2 FFTs of size 2048 per frame on the decimated signal,
~47 frames/s → well under 1 ms per frame in JS on an A-series chip (a reported MPM tuner
at ~11 kHz decimated runs 0.22 ms/frame). Direct O(N·W) NSDF at 1024×~170 lags is also
fine (~175k MACs/frame, ~8M/s). Expect ≪ 5 % of one core; the Flutter needle rendering
will cost more than detection. Keep the tuner screen free of heavy blur layers behind the
animated needle.

## 4. Features

- **Tunings (built-in presets):** Standard E A D G B E; Drop D (D A D G B E);
  Half-step down (Eb Ab Db Gb Bb Eb); Full-step down (D G C F A D); DADGAD; Open G (D G D G B D);
  Open D (D A D F# A D); Open E; Drop C. Store as MIDI note lists; custom tunings later.
- **Modes:** Auto (string detected) / Manual (tap a string, needle only for that target) / Chromatic.
- **A4 calibration:** 432–446 Hz, default 440, persisted locally (`shared_preferences`).
- **Reference tone:** Web Audio oscillator – plucked-ish tone (sum of harmonics + exp. decay)
  for each string; mic muted/ignored while tone plays to avoid self-detection.
- **UI:** big note name, cents readout, needle/strip, flat/sharp arrows, string row with
  per-string "done" check. Czech labels ("Ladička", "Automaticky", "Chromatická").
- **Privacy:** no network calls at all from the tuner; say so on the screen.

## 5. Risks, unknowns, test plan

**Risks**
1. **iOS audio session** (main risk): mic open ⇒ play-and-record ⇒ just_audio playback can
   go to earpiece/quiet and may not fully recover until all tracks are stopped; after the
   tuner closes, the next track may still start quiet on some iOS versions. Must be
   verified on the user's iPhone; mitigation above (pause music, stop tracks, close context,
   reset `audioSession.type`).
2. **Re-prompt every launch / on hash navigation** in standalone mode (WebKit 215884) –
   annoying, not fixable from the web side; native app fixes it.
3. **Residual voice processing** on some iOS versions even with EC off – check `getSettings()`
   and measure low-E response.
4. **Main-thread jank** in CanvasKit on older iPhones → keep detection in the worklet.
5. iOS beta regressions breaking `getUserMedia`.

**Test plan**
- **Unit (Dart/Node, no device):** feed generated signals into the same detector code:
  pure sines 73.4–1318 Hz at ±0, ±1, ±5, ±20 cents → |error| < 0.5 cent; synthetic
  "guitar" (fundamental weaker than 2nd/3rd harmonics, exponential decay, slight
  inharmonicity) → no octave errors; add white noise at 20 dB SNR; 44.1 vs 48 kHz.
- **Recorded samples:** a few WAVs of each open string (clean + phone-mic recording with room
  noise) in a test fixture; assert detected note and cents stability (std-dev < 1 cent over
  the sustain phase).
- **Cross-check:** tune with GuitarTuna / a clip-on tuner, then read Opentify – within ±2 cents.
- **iPhone manual checklist:** first grant, relaunch (re-prompt?), navigate away and back,
  incoming call / Siri interruption, lock screen, Bluetooth headphones connected,
  music playing → open tuner → close → does music resume at normal volume on the speaker?
- **Desktop Chrome:** same with a USB interface / laptop mic.

## Sources
- WebKit 215884 – standalone re-prompt on hash change: https://bugs.webkit.org/show_bug.cgi?id=215884
- WebKit 179411 – echoCancellation constraint: https://bugs.webkit.org/show_bug.cgi?id=179411
- WebKit 230902 – iOS 15 low playback volume with capture: https://bugs.webkit.org/show_bug.cgi?id=230902
- iOS Safari audio sessions write-up: https://samueleddy.com/writing/ios-safari-audio-sessions/
- Route switch to speaker with getUserMedia: https://medium.com/@python-javascript-php-html-css/ios-safari-forces-audio-output-to-speakers-when-using-getusermedia-2615196be6fe
- Capacitor issue – re-prompt after reopen: https://github.com/ionic-team/capacitor/issues/5580
- iOS 26.1 beta mic breakage: https://developer.apple.com/forums/thread/802555
- Audio Session API: https://developer.mozilla.org/en-US/docs/Web/API/Navigator/audioSession , https://github.com/w3c/audio-session/blob/main/explainer.md
- getUserMedia audio constraints: https://blog.addpipe.com/getusermedia-audio-constraints/
- McLeod thesis (MPM): https://www.cs.otago.ac.nz/research/publications/oucs-2008-03.pdf
- Pitch detection overview: https://en.wikipedia.org/wiki/Pitch_detection_algorithm
- YIN vs MPM discussion: https://github.com/sevagh/pitch-detection/issues/63
- MPM tuner cost example: https://github.com/OlivierTrudeau/guitar-scroll/pull/2
- pitchy: https://github.com/ianprime0509/pitchy · pitchfinder: https://github.com/peterkhayes/pitchfinder · aubiojs: https://github.com/qiuxiang/aubiojs
