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

// Malé okno: obal | název | tlačítka v řádku. Zvětšené (výška ≥ 170):
// obal a název nahoře, tlačítka pod nimi -- jako Spotify.
const _html = '''
<style>
  html, body { margin: 0; height: 100%; background: #17171b; color: #fff;
    font: 14px system-ui, -apple-system, "Segoe UI", sans-serif; overflow: hidden; user-select: none; }
  #root { height: 100%; box-sizing: border-box; padding: 10px 12px 14px; display: grid;
    grid-template-columns: auto 1fr auto; grid-template-areas: "art meta ctl"; align-items: center; gap: 12px; position: relative; }
  #art { grid-area: art; width: 56px; height: 56px; border-radius: 6px; object-fit: cover; background: #2a2a30; }
  #meta { grid-area: meta; min-width: 0; }
  #title { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  #artist { opacity: .7; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 2px; }
  #ctl { grid-area: ctl; display: flex; align-items: center; gap: 6px; }
  button { background: none; border: 0; color: #fff; cursor: pointer; padding: 6px; border-radius: 50%;
    display: grid; place-items: center; font: 600 13px system-ui, sans-serif; }
  button:hover { background: rgba(255,255,255,.1); }
  button svg { width: 24px; height: 24px; fill: currentColor; }
  #play { background: #fff; color: #000; width: 40px; height: 40px; }
  #play:hover { background: #ddd; }
  /* Srdíčko místo Spotify ⊕: prázdné obrysové, v Oblíbených plné červené. */
  #like svg { fill: none; stroke: currentColor; stroke-width: 2; }
  #like.on { color: #ff5252; }
  #like.on svg { fill: currentColor; }
  #like.hide { display: none; }
  #bar { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: rgba(255,255,255,.15); }
  #fill { height: 100%; width: 0; background: #fff; }
  @media (min-height: 170px) {
    #root { grid-template-columns: auto 1fr; grid-template-rows: 1fr auto;
      grid-template-areas: "art meta" "ctl ctl"; padding: 14px 16px 18px; }
    #art { width: 96px; height: 96px; }
    #title { font-size: 17px; }
    #ctl { justify-content: center; gap: 14px; }
    #play { width: 48px; height: 48px; }
  }
</style>
<div id="root">
  <img id="art" alt="">
  <div id="meta"><div id="title"></div><div id="artist"></div></div>
  <div id="ctl">
    <button id="like" title="Oblíbené">${'<svg viewBox="0 0 24 24"><path d="$_heart"/></svg>'}</button>
    <button id="prev" title="Předchozí"></button>
    <button id="play" title="Přehrát / pozastavit"></button>
    <button id="next" title="Další"></button>
  </div>
  <div id="bar"><div id="fill"></div></div>
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
