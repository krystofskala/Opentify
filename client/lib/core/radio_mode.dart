import 'radio_mode_stub.dart' if (dart.library.js_interop) 'radio_mode_web.dart' as impl;

/// Přehrávat frontu jako jeden nepřetržitý stream ze serveru (viz backend
/// app/radio.py)? Jen iPhone/iPad v prohlížeči -- tam webová appka na
/// zamčeném displeji nesmí spustit nový zdroj zvuku. Pro testování na PC
/// jde vynutit `?radio=1` v adrese.
bool shouldUseRadioStream() => impl.shouldUseRadioStream();

/// Umí prohlížeč HLS nativně (Safari)? Tam se rádio pouští jako HLS -- ten
/// stahuje systémový přehrávač i na pozadí; obyčejný MP3 stream iOS po
/// odchodu z appky přestal stahovat a přehrávání se zastavilo.
bool supportsNativeHls() => impl.supportsNativeHls();
