import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'pip_player.dart';

PipPlayer createPipPlayer() => _WebPipPlayer();

@JS('documentPictureInPicture')
external _DocPip? get _docPip;

extension type _DocPip._(JSObject _) implements JSObject {
  external JSPromise<web.Window> requestWindow([_PipOptions? options]);
}

extension type _PipOptions._(JSObject _) implements JSObject {
  external factory _PipOptions({int width, int height});
}

// Ikony Material Symbols (plné), vlastní HTML -- Flutter do okna nekreslí.
const _play = 'M8 5v14l11-7z';
const _pause = 'M6 19h4V5H6v14zm8-14v14h4V5h-4z';
const _next = 'M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z';
const _prev = 'M6 6h2v12H6zm3.5 6l8.5 6V6z';
const _heart =
    'M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z';

String _svg(String path) => '<svg viewBox="0 0 24 24"><path d="$path"/></svg>';

// Rozložení podle velikosti okna (jako Spotify): malé = řádek obal | název |
// tlačítka (u úzkého se postupně schová srdíčko, předchozí, název -- nic se
// neořízne); velké = obal přes celou šířku, pod ním název, průběh a větší
// tlačítka. Pozadí = rozmazaný obal.
const _html = '''
<style>
  html, body { margin: 0; height: 100%; background: #121214; color: #fff; overflow: hidden; user-select: none;
    font: 14px system-ui, -apple-system, "Segoe UI", sans-serif; -webkit-font-smoothing: antialiased; }
  #bg { position: fixed; inset: -60px; width: calc(100% + 120px); height: calc(100% + 120px); object-fit: cover;
    filter: blur(48px) saturate(1.5) brightness(.42); z-index: 0; }
  #root { position: relative; z-index: 1; height: 100%; box-sizing: border-box; padding: 10px 12px;
    display: flex; align-items: center; gap: 12px; }
  #artbox { flex: none; height: min(calc(100vh - 20px), 80px); aspect-ratio: 1; }
  #art { width: 100%; height: 100%; border-radius: 6px; object-fit: cover; background: #2a2a30;
    box-shadow: 0 6px 20px rgba(0,0,0,.45); display: block; }
  #meta { flex: 1 1 auto; min-width: 0; }
  #title { font-weight: 650; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  #artist { opacity: .72; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 2px; }
  #ctl { flex: none; display: flex; align-items: center; gap: 2px; }
  button { background: none; border: 0; color: #fff; cursor: pointer; padding: 0; width: 36px; height: 36px;
    border-radius: 50%; display: grid; place-items: center; font: 650 13px system-ui, sans-serif; transition: background .15s, transform .1s; }
  button:hover { background: rgba(255,255,255,.12); }
  button:active { transform: scale(.94); }
  button svg { width: 22px; height: 22px; fill: currentColor; }
  #play { width: 40px; height: 40px; background: #fff; color: #000; margin: 0 4px; }
  #play:hover { background: #e8e8e8; }
  /* Srdíčko místo Spotify ⊕: prázdné obrysové, v Oblíbených plné červené. */
  #like svg { fill: none; stroke: currentColor; stroke-width: 2; }
  #like.on { color: #ff5252; }
  #like.on svg { fill: currentColor; }
  #like.hide { display: none; }
  #bar { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: rgba(255,255,255,.18); }
  #fill { height: 100%; width: 0; background: #fff; border-radius: inherit; }
  @media (max-width: 340px) { #like { display: none; } }
  @media (max-width: 280px) { #prev { display: none; } }
  @media (max-width: 220px) { #meta { display: none; } #root { justify-content: space-between; } }
  @media (max-height: 62px) { #artist { display: none; } }
  @media (min-height: 230px) and (min-width: 220px) {
    #root { flex-direction: column; align-items: stretch; padding: 18px 20px 20px; gap: 12px; }
    #artbox { flex: 1 1 0; min-height: 0; height: auto; aspect-ratio: auto; container-type: size;
      display: flex; align-items: center; justify-content: center; }
    #art { width: min(100cqw, 100cqh); height: min(100cqw, 100cqh); border-radius: 8px; }
    #title { font-size: clamp(15px, 4.6vw, 24px); }
    #artist { font-size: clamp(13px, 3.4vw, 17px); margin-top: 4px; }
    #bar { position: relative; flex: none; height: 4px; border-radius: 2px; }
    #ctl { justify-content: center; gap: clamp(6px, 4vw, 22px); }
    button { width: 44px; height: 44px; }
    button svg { width: 28px; height: 28px; }
    #play { width: 58px; height: 58px; }
    #play svg { width: 32px; height: 32px; }
    #like { display: grid; }
    #like.hide { display: none; }
    #prev { display: grid; }
    #meta { display: block; }
  }
</style>
<img id="bg" alt="">
<div id="root">
  <div id="artbox"><img id="art" alt=""></div>
  <div id="meta"><div id="title"></div><div id="artist"></div></div>
  <div id="bar"><div id="fill"></div></div>
  <div id="ctl">
    <button id="like" title="Oblíbené">${'<svg viewBox="0 0 24 24"><path d="$_heart"/></svg>'}</button>
    <button id="prev" title="Předchozí"></button>
    <button id="play" title="Přehrát / pozastavit"></button>
    <button id="next" title="Další"></button>
  </div>
</div>
''';

class _WebPipPlayer implements PipPlayer {
  web.Window? _win;
  PipState? _last;
  void Function()? _onPlayPause, _onNext, _onPrevious, _onLike, _onOpened;

  @override
  bool get supported {
    try {
      return _docPip != null;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get isOpen => _win != null;

  @override
  void setHandlers({
    required void Function() onPlayPause,
    required void Function() onNext,
    required void Function() onPrevious,
    required void Function() onLike,
    void Function()? onOpened,
  }) {
    _onPlayPause = onPlayPause;
    _onNext = onNext;
    _onPrevious = onPrevious;
    _onLike = onLike;
    _onOpened = onOpened;
  }

  @override
  void setAutoOpen(bool on) {
    if (!supported) return;
    try {
      web.window.navigator.mediaSession.setActionHandler(
        'enterpictureinpicture',
        on
            ? ((JSAny? _) {
                open();
              }).toJS
            : null,
      );
    } catch (_) {
      // Prohlížeč akci nezná (starší Chrome, Edge bez podpory) -- jen ručně.
    }
  }

  @override
  Future<void> open() async {
    final pip = _docPip;
    if (pip == null || _win != null) return;
    final web.Window win;
    try {
      win = await pip.requestWindow(_PipOptions(width: 400, height: 150)).toDart;
    } catch (_) {
      return; // bez gesta uživatele / zamítnuto
    }
    _win = win;
    final doc = win.document;
    doc.title = 'Opentify';
    (doc.body! as JSObject).setProperty('innerHTML'.toJS, _html.toJS);
    void on(String id, void Function()? Function() handler) {
      doc.getElementById(id)?.addEventListener(
          'click',
          ((web.Event _) {
            handler()?.call();
          }).toJS);
    }

    on('play', () => _onPlayPause);
    on('next', () => _onNext);
    on('prev', () => _onPrevious);
    on('like', () => _onLike);
    win.addEventListener(
        'pagehide',
        ((web.Event _) {
          if (identical(_win, win)) _win = null;
        }).toJS);
    _last = null;
    _onOpened?.call();
  }

  @override
  void close() {
    try {
      _win?.close();
    } catch (_) {}
    _win = null;
  }

  @override
  void update(PipState s) {
    final prev = _last;
    _last = s;
    final doc = _win?.document;
    if (doc == null) return;
    web.Element? el(String id) => doc.getElementById(id);
    if (prev?.title != s.title) el('title')?.textContent = s.title;
    if (prev?.artist != s.artist) el('artist')?.textContent = s.artist ?? '';
    if (prev?.artworkUrl != s.artworkUrl) {
      // Okno je about:blank -- relativní adresu doplnit k adrese appky.
      final src = s.artworkUrl == null ? Uri.base.resolve('icons/Icon-192.png') : Uri.base.resolve(s.artworkUrl!);
      (el('art') as web.HTMLImageElement?)?.src = src.toString();
      (el('bg') as web.HTMLImageElement?)?.src = src.toString();
    }
    if (prev?.playing != s.playing) {
      (el('play') as JSObject?)?.setProperty('innerHTML'.toJS, _svg(s.playing ? _pause : _play).toJS);
    }
    if (prev?.spoken != s.spoken) {
      // Kniha / epizoda: ±30 s místo předchozí / další (jako zamčená obrazovka).
      (el('prev') as JSObject?)?.setProperty('innerHTML'.toJS, (s.spoken ? '−30' : _svg(_prev)).toJS);
      (el('next') as JSObject?)?.setProperty('innerHTML'.toJS, (s.spoken ? '+30' : _svg(_next)).toJS);
      el('prev')?.setAttribute('title', s.spoken ? 'Zpět o 30 s' : 'Předchozí');
      el('next')?.setAttribute('title', s.spoken ? 'Vpřed o 30 s' : 'Další');
    }
    if (prev?.liked != s.liked || prev?.spoken != s.spoken) {
      el('like')?.className = [if (s.liked) 'on', if (s.spoken) 'hide'].join(' ');
    }
    final pct = (s.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(1);
    (el('fill') as web.HTMLElement?)?.style.width = '$pct%';
  }
}
