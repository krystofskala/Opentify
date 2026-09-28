import 'dart:async';
import 'dart:math' show pow;
import 'dart:typed_data' show BytesBuilder;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
// Flutter má od 3.47 vlastní `RepeatMode` (`RepeatingAnimationBuilder`) --
// skrytý, ať nekoliduje s naším (viz níže).
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/media_session.dart';
import '../core/ws_client.dart';
import '../models/playback_model.dart' show RepeatMode;
import '../theme/accent_color.dart';
import 'artwork_provider.dart';
import 'provisioning_controller.dart';
import 'providers.dart';

// `RepeatMode` už existuje jako 1:1 model `PlaybackSession.repeatMode` z WS
// `playback.*` protokolu (docs/asyncapi.yaml, viz `models/playback_model.dart`)
// -- sdílíme ho, místo abychom si vedle vytvářeli druhý stejnojmenný enum se
// stejnými hodnotami jen jinde (navíc by kolidoval s `flutter/material.dart`
// vlastním `RepeatMode`, viz `RepeatingAnimationBuilder`). `export` ho
// zpřístupní i volajícím, co importují tenhle soubor (`NowPlayingScreen`
// apod.), bez druhého importu.
export '../models/playback_model.dart' show RepeatMode;

/// Metadata skladby pro zobrazení v `PlayerBar` -- na rozdíl od `models/`
/// (1:1 se schématy z docs/openapi.yaml) je tohle čistě lokální UI konstrukt,
/// sestavovaný z toho, co má volající po ruce (album, interpret) v okamžiku
/// kliknutí na "přehrát", ne ze samostatného API volání.
class NowPlayingInfo {
  const NowPlayingInfo({
    required this.recordingId,
    required this.title,
    this.artistName,
    this.artistId,
    this.releaseId,
    this.artworkUrl,
  });

  final String recordingId;
  final String title;
  final String? artistName;

  /// Umožní `PlayerBar`/`NowPlayingScreen` prokliknout jméno interpreta na
  /// jeho profil -- dřív se neslo jen zobrazitelné `artistName`, žádné ID,
  /// takže i kdyby byl text klikatelný, nebylo kam routovat.
  final String? artistId;

  /// Totéž pro proklik z názvu skladby na album -- bez tohohle nemělo
  /// `NowPlayingScreen` kam routovat, i kdyby byl název klikatelný.
  final String? releaseId;
  final String? artworkUrl;
}

class AudioPlayerState {
  const AudioPlayerState({
    this.nowPlaying,
    required this.isPlaying,
    required this.isBuffering,
    required this.position,
    this.duration,
    this.error,
    this.accentColor,
    this.queue = const [],
    this.queueIndex = -1,
    this.queueSourceLabel,
    this.shuffleEnabled = false,
    this.shuffleOrder,
    this.repeatMode = RepeatMode.off,
    this.speed = 1.0,
    this.volume = 1.0,
    this.sleepTimerEndAt,
    this.recentlyPlayed = const [],
    this.normalizationEnabled = true,
  });

  const AudioPlayerState.idle()
      : nowPlaying = null,
        isPlaying = false,
        isBuffering = false,
        position = Duration.zero,
        duration = null,
        error = null,
        accentColor = null,
        queue = const [],
        queueIndex = -1,
        recentlyPlayed = const [],
        queueSourceLabel = null,
        shuffleEnabled = false,
        shuffleOrder = null,
        repeatMode = RepeatMode.off,
        speed = 1.0,
        volume = 1.0,
        sleepTimerEndAt = null,
        normalizationEnabled = true;

  final NowPlayingInfo? nowPlaying;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration? duration;
  final String? error;

  /// Dominantní/vibrantní barva z obalu právě hrající skladby (viz
  /// `AudioPlayerController._extractAccentColor`) -- pohání "PixelPlay"
  /// dynamické zabarvení `PlayerBar` a M3 seed appky v `app.dart`. `null`,
  /// dokud se obal nestáhne/nezanalyzuje, nebo když skladba žádný obal nemá.
  final Color? accentColor;

  /// Seznam, ze kterého se aktuálně hraje (album, naskenovaná knihovna,
  /// doporučení...) -- umožňuje Předchozí/Další v `NowPlayingScreen`. Volající
  /// (viz `TrackTile.queueRecordings`) ho posílá jen tam, kde má smysl;
  /// jinak jde o jednoprvkovou frontu a skladba hraje osamoceně.
  final List<NowPlayingInfo> queue;
  final int queueIndex;

  /// "Přehráváno z X" (název alba/playlistu/sekce, co frontu spustil) --
  /// viz `TrackTile.sourceLabel`. `null`, když volající kontext žádný nemá
  /// (např. Shuffle přímo z jednoho seznamu bez jasného "zdroje").
  final String? queueSourceLabel;

  final bool shuffleEnabled;

  /// Permutace indexů `queue`, platná jen když `shuffleEnabled`. `[0]` je
  /// vždy aktuální `queueIndex` v okamžiku zapnutí shuffle -- zapnutí
  /// uprostřed poslechu tak neposkočí jinam, jen zamíchá zbytek fronty.
  /// Zůstává (nevynulovává se) i po vypnutí shuffle, aby opětovné zapnutí na
  /// stejné frontě nemuselo počítat nové pořadí -- `shuffleEnabled` samo
  /// řídí, jestli se vůbec použije (viz `nextIndex`/`previousIndex`).
  final List<int>? shuffleOrder;

  final RepeatMode repeatMode;

  /// Rychlost přehrávání (0.5-2.0), viz `AudioPlayerController.setSpeed`.
  final double speed;

  /// Hlasitost (0.0-1.0), viz `AudioPlayerController.setVolume` -- vždy
  /// uživatelova hodnota, BEZ korekce normalizace (ta se násobí až při
  /// předání do přehrávače, viz `AudioPlayerController._effectiveVolume`).
  final double volume;

  /// "Normalizace hlasitosti" -- vzor z Finampu (ReplayGain), per-zařízení
  /// uložené v `SharedPreferences`.
  final bool normalizationEnabled;

  /// Absolutní čas, kdy uspávač přehrávání zastaví -- `null`, když neběží.
  /// Zámerně abstolutní, ne "zbývající sekundy": UI si odpočet dopočítává
  /// samo lokálním časovačem, aby nastavení časovače nevyžadovalo
  /// sekundový tik přes celý stavový strom appky.
  final DateTime? sleepTimerEndAt;

  /// Naposledy přehrané skladby, nejnovější první, bez duplicit -- pohání
  /// PixelPlayerovu "bublinovou" `RecentlyPlayedPill` řadu na Home. Jen v
  /// paměti (resetuje se s obnovením stránky), stejně jako uspávač -- appka
  /// nikde jinde stav mezi relacemi neukládá.
  final List<NowPlayingInfo> recentlyPlayed;

  int? get _shufflePosition => shuffleOrder?.indexOf(queueIndex);

  /// Index skladby, na kterou skočí `next()` -- `null`, když fronta končí a
  /// `repeatMode != all` (žádná legitimní další skladba).
  int? get nextIndex {
    if (queue.isEmpty) return null;
    if (shuffleEnabled && shuffleOrder != null) {
      final pos = _shufflePosition;
      if (pos == null) return null;
      if (pos + 1 < shuffleOrder!.length) return shuffleOrder![pos + 1];
      return repeatMode == RepeatMode.all ? shuffleOrder!.first : null;
    }
    if (queueIndex + 1 < queue.length) return queueIndex + 1;
    return repeatMode == RepeatMode.all && queue.isNotEmpty ? 0 : null;
  }

  /// Index skladby, na kterou skočí `previous()` -- na rozdíl od `nextIndex`
  /// se nezacykluje na `repeatMode == all` (typické chování přehrávačů:
  /// "předchozí" na první skladbě buď nic nedělá, nebo jen restartuje ji
  /// samotnou, neskáče na konec fronty).
  int? get previousIndex {
    if (queue.isEmpty) return null;
    if (shuffleEnabled && shuffleOrder != null) {
      final pos = _shufflePosition;
      if (pos == null || pos <= 0) return null;
      return shuffleOrder![pos - 1];
    }
    return queueIndex > 0 ? queueIndex - 1 : null;
  }

  bool get hasPrevious => previousIndex != null;
  bool get hasNext => nextIndex != null;

  AudioPlayerState copyWith({
    NowPlayingInfo? nowPlaying,
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? duration,
    String? error,
    Color? accentColor,
    List<NowPlayingInfo>? queue,
    int? queueIndex,
    String? queueSourceLabel,
    bool? shuffleEnabled,
    List<int>? shuffleOrder,
    RepeatMode? repeatMode,
    double? speed,
    double? volume,
    List<NowPlayingInfo>? recentlyPlayed,
    bool? normalizationEnabled,
  }) {
    return AudioPlayerState(
      nowPlaying: nowPlaying ?? this.nowPlaying,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      // Bez `?? this.error` by libovolný běžný update (pozice, stav
      // přehrávače -- ty chodí i po chybě dál) chybu okamžitě po nastavení
      // zase smazal, takže by v UI nikdy nestihla naskočit -- selhání
      // přehrání pak vypadalo, jako by se nedělo vůbec nic. Nový pokus o
      // přehrání (`playTrack`/skip) chybu čistí tím, že staví úplně nový
      // `AudioPlayerState`, ne přes `copyWith`.
      error: error ?? this.error,
      accentColor: accentColor ?? this.accentColor,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      queueSourceLabel: queueSourceLabel ?? this.queueSourceLabel,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      shuffleOrder: shuffleOrder ?? this.shuffleOrder,
      repeatMode: repeatMode ?? this.repeatMode,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      sleepTimerEndAt: sleepTimerEndAt,
      recentlyPlayed: recentlyPlayed ?? this.recentlyPlayed,
      normalizationEnabled: normalizationEnabled ?? this.normalizationEnabled,
    );
  }

  /// `copyWith` nejde použít pro vynulování `sleepTimerEndAt` zpátky na
  /// `null` (jeho `?? this.sleepTimerEndAt` vzorec by starou hodnotu jen
  /// podržel) -- proto samostatná metoda pro tenhle jediný nullable case.
  AudioPlayerState withSleepTimerEndAt(DateTime? endAt) {
    return AudioPlayerState(
      nowPlaying: nowPlaying,
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      position: position,
      duration: duration,
      error: error,
      accentColor: accentColor,
      queue: queue,
      queueIndex: queueIndex,
      queueSourceLabel: queueSourceLabel,
      shuffleEnabled: shuffleEnabled,
      shuffleOrder: shuffleOrder,
      repeatMode: repeatMode,
      speed: speed,
      volume: volume,
      sleepTimerEndAt: endAt,
      recentlyPlayed: recentlyPlayed,
      normalizationEnabled: normalizationEnabled,
    );
  }
}

/// Skutečné (lokální) přehrávání zvuku přes `just_audio` -- na rozdíl od
/// `state/playback_controller.dart` (který jen zrcadlí `playback.*`/`queue.*`
/// WS protokol pro budoucí multi-device sync, viz jeho dokumentační komentář)
/// tenhle kontroler je to, co dnes skutečně pouští zvuk v prohlížeči/na
/// zařízení. Zůstává informovat `RealtimeClient` o play/pause/seek, aby
/// ostatní zařízení -- až server `playback.*` doimplementuje -- viděla
/// stejný stav; dokud server tyhle zprávy nezpracovává, jde jen o no-op
/// odeslání navíc.
class AudioPlayerController extends StateNotifier<AudioPlayerState> {
  AudioPlayerController(this._realtime, this._ref) : super(const AudioPlayerState.idle()) {
    _configureSession();
    unawaited(_loadPreferences());
    _player.playerStateStream.listen(_onPlayerStateChanged);
    _player.positionStream.listen((position) {
      if (_priming) return;
      state = state.copyWith(position: position);
      _maybeWarmUpNext(position);
      _trackScrobble(position);
    });
    _player.durationStream.listen((duration) {
      if (_priming) return;
      state = state.copyWith(duration: duration);
    });
    _mediaSession.setHandlers(
      onPlay: () => unawaited(_setPlaying(true)),
      onPause: () => unawaited(_setPlaying(false)),
      onNext: () => unawaited(next()),
      onPrevious: () => unawaited(previous()),
      onSeek: (position) => unawaited(seek(position)),
    );
    addListener(_syncMediaSession, fireImmediately: false);
  }

  final MediaSessionBridge _mediaSession = MediaSessionBridge();
  String? _mediaSessionKey;
  bool? _mediaSessionPlaying;
  Duration? _mediaSessionDuration;

  /// Zamčená obrazovka/Ovládací centrum: metadata jen při změně skladby nebo
  /// obalu, stav přehrávání při play/pause, pozice jen když se změní délka
  /// nebo stav (systém si ji dál dopočítává sám z `playbackRate`) -- ne na
  /// každý tik `positionStream`u.
  void _syncMediaSession(AudioPlayerState s) {
    final info = s.nowPlaying;
    if (info == null) {
      if (_mediaSessionKey != null) _mediaSession.clear();
      _mediaSessionKey = null;
      return;
    }
    final key = '${info.recordingId}|${info.artworkUrl}|${info.artistName}';
    if (key != _mediaSessionKey) {
      _mediaSessionKey = key;
      _mediaSession.setMetadata(
        title: info.title,
        artist: info.artistName,
        album: s.queueSourceLabel,
        artworkUrl: info.artworkUrl,
      );
    }
    if (s.isPlaying != _mediaSessionPlaying || s.duration != _mediaSessionDuration) {
      _mediaSessionPlaying = s.isPlaying;
      _mediaSessionDuration = s.duration;
      _mediaSession.setPlaying(s.isPlaying);
      _mediaSession.setPosition(position: s.position, duration: s.duration, speed: s.speed);
    }
  }

  Future<void> _setPlaying(bool playing) async {
    if (state.nowPlaying == null || _player.playing == playing) return;
    await togglePlayPause();
  }

  static const _normalizationPrefKey = 'player.normalization_enabled';

  /// Násobič hlasitosti z normalizace pro PRÁVĚ hrající skladbu (1.0 = bez
  /// korekce). Mimo `AudioPlayerState` -- UI ho nepotřebuje, jen přehrávač.
  double _trackGainFactor = 1.0;
  Timer? _gainRampTimer;

  /// `recordingId` skladby, pro kterou už proběhlo "zahřátí" následující
  /// skladby ve frontě (`_maybeWarmUpNext`) -- ať se to nespouští při každém
  /// tiku pozice znovu.
  String? _warmedUpAfter;

  final RealtimeClient _realtime;
  final Ref _ref;
  final AudioPlayer _player = AudioPlayer();
  Timer? _sleepTimer;

  /// Poslední úsek uspávače se hlasitost lineárně ztlumí místo tvrdého
  /// zastavení -- vzor z Finampova uspávače (`music_player_background_task.dart`,
  /// github.com/finamp-app/finamp, MPL-2.0), vlastní implementace nad naším
  /// `just_audio`. Veřejné, ať `player_more_sheet.dart` může ve stejném
  /// okně ukázat "Ztlumuje se..." místo odpočtu.
  static const sleepTimerFadeDuration = Duration(seconds: 10);
  Timer? _fadeTimer;

  /// Sleduje `ProvisioningController` po dobu čekání na `track.available`
  /// pro skladbu, která při `_playCurrent()` nebyla ještě AVAILABLE (HTTP
  /// 202). Zrušená při přepnutí na jinou skladbu i při `dispose()` -- jinak
  /// by pozdě doběhnuvší event z obstarávání staré skladby mohl spustit
  /// přehrávání přes tu, na kterou uživatel mezitím přeskočil.
  ProviderSubscription<Map<String, TrackProvisioningState>>? _provisioningSub;

  /// `true` mezi `_waitForAvailability` a `_startStream`/chybou -- v tomhle
  /// okně `_player` ještě nemá nastavený nový zdroj (žádný `setUrl` proběhl),
  /// takže `_onPlayerStateChanged` by bez tohoto přepínače mohl doručit
  /// zastaralý stav (`idle`/`completed` z předchozí skladby) a přepsat
  /// `isBuffering` zpátky na `false`, zatímco ve skutečnosti ještě čekáme na
  /// `track.available` z ingestion pipeline.
  bool _awaitingProvisioning = false;

  /// Cache podle `recordingId` -- obal/barva, co appka pro skladbu jednou
  /// dohledala/spočítala, se znovu nefetchuje/nepočítá při každém dalším
  /// přepnutí na ni (`next`/`previous`/swipe/opakované přehrání). Bez týhle
  /// cache `playQueue`/`_playAtIndex` (oba nulují `accentColor` na začátku
  /// nové skladby) na zlomek sekundy bleslo výchozí barvou při KAŽDÉM
  /// přepnutí, i na už dřív viděnou skladbu.
  final Map<String, String> _artworkCache = {};
  final Map<String, Color> _accentColorCache = {};

  Future<void> _configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  /// Přehraje jedinou skladbu bez kontextu seznamu -- fronta má jen tenhle
  /// jeden prvek, takže Předchozí/Další v `NowPlayingScreen` zůstanou
  /// neaktivní. Volající, co mají po ruce celý seznam (tracklist alba,
  /// knihovna...), by měli volat `playQueue` místo tohohle.
  Future<void> playTrack(NowPlayingInfo info, {String? sourceLabel}) => playQueue([info], 0, sourceLabel: sourceLabel);

  /// Přehraje `items[startIndex]` a zbytek seznamu si uloží jako frontu pro
  /// `next()`/`previous()`. `sourceLabel` (např. název alba/playlistu) se
  /// zobrazí v `NowPlayingScreen` jako "Přehráváno z X". Shuffle/repeat/
  /// speed/volume z předchozí fronty přetrvávají (jsou to nastavení
  /// přehrávače, ne téhle konkrétní fronty), jen se pro novou frontu
  /// přepočítá `shuffleOrder`.
  ///
  /// `prefetchWholeQueue`: jen explicitní "Přehrát/Zamíchat" alba/playlistu
  /// (uživatel chtěl, ať se stáhne celé album). Jinde -- výsledky hledání,
  /// řady na Domů, klepnutí na jednu skladbu -- se předem stahuje jen další
  /// skladba; dřív se stahoval celý seznam a jedno přehrání z hledání tak
  /// stáhlo všechny výsledky (zbytečná zátěž a místo na disku).
  Future<void> playQueue(
    List<NowPlayingInfo> items,
    int startIndex, {
    String? sourceLabel,
    bool prefetchWholeQueue = false,
  }) async {
    if (items.isEmpty) return;
    final index = startIndex.clamp(0, items.length - 1);
    _primeAudioElement(items[index].recordingId);
    state = AudioPlayerState(
      nowPlaying: items[index],
      isPlaying: false,
      isBuffering: true,
      position: Duration.zero,
      duration: null,
      // Seedne z cache, když jsme tuhle skladbu už přehrávali -- bez tohohle
      // by UI na zlomek sekundy bleslo výchozí (fialovou) barvou při KAŽDÉM
      // přepnutí, i na skladbu, jejíž barvu už dávno známe.
      accentColor: _accentColorCache[items[index].recordingId],
      queue: items,
      queueIndex: index,
      queueSourceLabel: sourceLabel,
      shuffleEnabled: state.shuffleEnabled,
      shuffleOrder: state.shuffleEnabled ? _buildShuffleOrder(items.length, index) : null,
      repeatMode: state.repeatMode,
      speed: state.speed,
      volume: state.volume,
      recentlyPlayed: state.recentlyPlayed,
      normalizationEnabled: state.normalizationEnabled,
      sleepTimerEndAt: state.sleepTimerEndAt,
    );
    // POŘADÍ ZÁMĚRNĚ TAKHLE -- `_playCurrent()` (a jeho `POST /provision` pro
    // právě přehrávanou skladbu) musí na server dorazit DŘÍV, než začnou
    // `_prefetchQueue`ovy requesty pro zbytek alba. Redis Stream frontí podle
    // pořadí příchodu (XADD), takže opačné pořadí (živě pozorováno) mohlo
    // nechat skladbu, na kterou uživatel čeká, stát ve frontě ZA deseti
    // dalšími z prefetche, místo aby ji tři workery zpracovaly jako první.
    await _playCurrent();
    if (prefetchWholeQueue) {
      _prefetchQueue(items, except: items[index].recordingId);
    } else {
      // Další skladbu až ve 80 % té aktuální řeší `_maybeWarmUpNext`; tady
      // jen ta úplně první následující, ať přeskočení hned na začátku nečeká.
      final next = state.nextIndex;
      if (next != null && next != index) {
        unawaited(_ref.read(provisioningControllerProvider.notifier).provision(items[next].recordingId));
      }
    }
  }

  /// Spustí obstarávání zbytku fronty na pozadí, souběžně s přehráváním
  /// první skladby -- "přehrát celé album" by jinak stáhlo skladby jednu po
  /// druhé, až na ně přišla řada (`next()` -> `_playCurrent()`), takže by
  /// uživatel čekal u KAŽDÉ skladby zvlášť místo jednou na začátku. `except`
  /// vynechá právě přehrávanou skladbu -- tu už `provision()` volá
  /// `_playCurrent()` sám, druhé volání navíc by byl jen zbytečný duplicitní
  /// HTTP request. Serverový `provision()` je idempotentní (viz
  /// `get_or_create_job`), takže souběžné volání pro stejnou nahrávku z
  /// jiného místa appky nic nezdvojí.
  void _prefetchQueue(List<NowPlayingInfo> items, {required String except}) {
    final provisioning = _ref.read(provisioningControllerProvider.notifier);
    for (final item in items) {
      if (item.recordingId == except) continue;
      unawaited(provisioning.provision(item.recordingId));
    }
  }

  Future<void> next() async {
    final index = state.nextIndex;
    if (index == null) return;
    await _playAtIndex(index);
  }

  /// Standardní UX napříč přehrávači (Spotify, Finamp...): první ~3s skladby
  /// "Předchozí" skočí na předchozí skladbu, později jen restartuje tu
  /// aktuální -- jinak by neúmyslné dvojité kliknutí za sebou přeskočilo o
  /// dvě skladby zpátky místo restartu poslouchané.
  Future<void> previous() async {
    if (state.position > const Duration(seconds: 3) || state.previousIndex == null) {
      await seek(Duration.zero);
      return;
    }
    await _playAtIndex(state.previousIndex!);
  }

  /// Přeskočí přímo na `index` ve frontě (bez ohledu na shuffle pořadí) --
  /// pro `QueuePanel`, kde uživatel klepne na konkrétní řádek.
  Future<void> skipToIndex(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _playAtIndex(index);
  }

  /// Přeskládá frontu (`SliverReorderableList.onReorderItem` v `QueuePanel`
  /// -- `newIndex` je už finální cílová pozice po odebrání `oldIndex`, žádná
  /// další úprava tady není potřeba). Shuffle se při ručním přeskládání
  /// vypne -- `shuffleOrder` odkazuje na indexy před přeskládáním a po něm
  /// by ukazoval na jiné skladby, a uživatel si zrovna pořadí poskládal
  /// sám, takže by ho stejně hned zase přebilo.
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex == newIndex || oldIndex < 0 || oldIndex >= state.queue.length) return;
    final newQueue = [...state.queue];
    final moved = newQueue.removeAt(oldIndex);
    newQueue.insert(newIndex, moved);

    var newCurrentIndex = state.queueIndex;
    if (oldIndex == state.queueIndex) {
      newCurrentIndex = newIndex;
    } else if (oldIndex < state.queueIndex && newIndex >= state.queueIndex) {
      newCurrentIndex -= 1;
    } else if (oldIndex > state.queueIndex && newIndex <= state.queueIndex) {
      newCurrentIndex += 1;
    }

    state = state.copyWith(queue: newQueue, queueIndex: newCurrentIndex, shuffleEnabled: false);
  }

  /// Vloží skladbu hned za právě hrající, bez přerušení aktuálního
  /// přehrávání -- "Přehrát jako další" (vlastní implementace inspirovaná
  /// UX Musify's `song_bar.dart`, github.com/gokadzev/Musify, GPL-3.0; jejich
  /// verze je vázaná na `audio_service`'s frontu, tahle na naši
  /// `AudioPlayerState.queue`). Když zrovna nic nehraje, chová se jako
  /// `playTrack`.
  Future<void> playNext(NowPlayingInfo info) async {
    if (state.nowPlaying == null) {
      await playTrack(info);
      return;
    }
    final insertAt = state.queueIndex + 1;
    final newQueue = [...state.queue]..insert(insertAt, info);
    // Shuffle pořadí odkazuje na indexy do fronty -- bez přepočtu by vložení
    // posunulo všechno za `insertAt` o jednu pozici a nová skladba by v
    // pořadí chyběla úplně (next()/previous() by ji nikdy nenašly).
    var newShuffleOrder = state.shuffleOrder;
    if (state.shuffleEnabled && newShuffleOrder != null) {
      final shifted = newShuffleOrder.map((i) => i >= insertAt ? i + 1 : i).toList();
      shifted.insert(shifted.indexOf(state.queueIndex) + 1, insertAt);
      newShuffleOrder = shifted;
    }
    state = state.copyWith(queue: newQueue, shuffleOrder: newShuffleOrder);
    unawaited(_ref.read(provisioningControllerProvider.notifier).provision(info.recordingId));
  }

  /// Přidá skladbu na konec fronty, ať hraje/nehraje cokoliv jiného. Když
  /// zrovna nic nehraje, chová se jako `playTrack`.
  Future<void> addToQueue(NowPlayingInfo info) async {
    if (state.nowPlaying == null) {
      await playTrack(info);
      return;
    }
    final newIndex = state.queue.length;
    final newQueue = [...state.queue, info];
    var newShuffleOrder = state.shuffleOrder;
    if (state.shuffleEnabled && newShuffleOrder != null) {
      newShuffleOrder = [...newShuffleOrder, newIndex];
    }
    state = state.copyWith(queue: newQueue, shuffleOrder: newShuffleOrder);
    unawaited(_ref.read(provisioningControllerProvider.notifier).provision(info.recordingId));
  }

  void toggleShuffle() {
    final enabling = !state.shuffleEnabled;
    state = state.copyWith(
      shuffleEnabled: enabling,
      shuffleOrder: enabling ? _buildShuffleOrder(state.queue.length, state.queueIndex) : state.shuffleOrder,
    );
  }

  List<int> _buildShuffleOrder(int length, int currentIndex) {
    final indices = List<int>.generate(length, (i) => i)..shuffle();
    indices.remove(currentIndex);
    indices.insert(0, currentIndex);
    return indices;
  }

  void cycleRepeatMode() {
    final next = switch (state.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    state = state.copyWith(repeatMode: next);
  }

  Future<void> setSpeed(double value) async {
    await _player.setSpeed(value);
    state = state.copyWith(speed: value);
  }

  Future<void> setVolume(double value) async {
    state = state.copyWith(volume: value);
    if (_fadeTimer == null) await _player.setVolume(_effectiveVolume);
  }

  /// Uživatelova hlasitost vynásobená korekcí normalizace. Jen zeslabení --
  /// `just_audio` na webu (HTML `<audio>.volume`) neumí nad 1.0, takže tiché
  /// skladby (kladná korekce) hrají prostě na uživatelově hlasitosti.
  double get _effectiveVolume =>
      (state.volume * (state.normalizationEnabled ? _trackGainFactor : 1.0)).clamp(0.0, 1.0);

  static double _factorForGainDb(double? gainDb) {
    if (gainDb == null) return 1.0;
    return pow(10, gainDb / 20).toDouble().clamp(0.0, 1.0);
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_normalizationPrefKey);
      if (enabled != null && enabled != state.normalizationEnabled) {
        state = state.copyWith(normalizationEnabled: enabled);
        _applyVolume();
      }
    } catch (_) {
      // Bez uložené preference prostě zůstane výchozí (zapnuto).
    }
  }

  Future<void> setNormalizationEnabled(bool enabled) async {
    state = state.copyWith(normalizationEnabled: enabled);
    _rampToEffectiveVolume();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_normalizationPrefKey, enabled);
    } catch (_) {}
  }

  /// Okamžitě nastaví efektivní hlasitost -- kromě doby, kdy běží ztlumování
  /// uspávače (ten si hlasitost řídí sám a přepsal by se).
  void _applyVolume() {
    if (_fadeTimer != null) return;
    _gainRampTimer?.cancel();
    _gainRampTimer = null;
    unawaited(_player.setVolume(_effectiveVolume));
  }

  /// Plynulý (~1 s) přechod na novou efektivní hlasitost -- pro korekci,
  /// co dorazí až během přehrávání (čerstvě obstaraná skladba se měří až po
  /// `track.available`), ať to nezní jako skokové ztišení.
  void _rampToEffectiveVolume() {
    if (_fadeTimer != null) return;
    _gainRampTimer?.cancel();
    final from = _player.volume;
    final to = _effectiveVolume;
    if ((from - to).abs() < 0.01) {
      unawaited(_player.setVolume(to));
      return;
    }
    const steps = 20;
    var step = 0;
    _gainRampTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      step += 1;
      final t = step / steps;
      unawaited(_player.setVolume(from + (to - from) * t));
      if (step >= steps) {
        timer.cancel();
        _gainRampTimer = null;
      }
    });
  }

  /// Korekci pro skladbu, co právě začíná, vezme z cache (`provision()` ji u
  /// už stažených skladeb vrací rovnou) -- když tam není, zeptá se backendu,
  /// a u čerstvě obstarané skladby (měří se až pár sekund po
  /// `track.available`) to zkusí ještě dvakrát se zpožděním.
  Future<void> _loadGainFor(String recordingId) async {
    final provisioning = _ref.read(provisioningControllerProvider.notifier);
    for (final delay in const [Duration.zero, Duration(seconds: 6), Duration(seconds: 20)]) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (state.nowPlaying?.recordingId != recordingId) return;
      final gain = await provisioning.fetchLoudnessGain(recordingId);
      if (state.nowPlaying?.recordingId != recordingId) return;
      if (gain != null) {
        _trackGainFactor = _factorForGainDb(gain);
        _rampToEffectiveVolume();
        return;
      }
    }
  }

  /// "Gapless-light" (vzor z Finampova prefetche, vlastní implementace):
  /// ~80 % skladby / posledních 20 s zajistí, že DALŠÍ skladba ve frontě je
  /// obstaraná (znovu zkusí i dřívější neúspěšný prefetch), má dohledaný
  /// obal+barvu a korekci hlasitosti -- auto-přechod a "Další" pak startují
  /// z cache místo čekání. Skutečné bezmezerové přehrávání
  /// (`ConcatenatingAudioSource`) tu záměrně není: naše fronta se obstarává
  /// per-skladba až za běhu a stream URL existuje teprve po `track.available`,
  /// takže by se playlist zdroje musel neustále přestavovat.
  void _maybeWarmUpNext(Duration position) {
    final current = state.nowPlaying;
    final duration = state.duration;
    if (current == null || duration == null || duration == Duration.zero) return;
    if (_warmedUpAfter == current.recordingId) return;
    final remaining = duration - position;
    if (position < duration * 0.8 && remaining > const Duration(seconds: 20)) return;

    _warmedUpAfter = current.recordingId;
    final nextIndex = state.nextIndex;
    if (nextIndex == null || nextIndex >= state.queue.length) return;
    final next = state.queue[nextIndex];
    if (next.recordingId == current.recordingId) return;

    final provisioning = _ref.read(provisioningControllerProvider.notifier);
    final nextState = _ref.read(provisioningControllerProvider)[next.recordingId];
    if (nextState == null || (!nextState.isAvailable && !nextState.isInFlight && nextState.streamUrl == null)) {
      unawaited(provisioning.provision(next.recordingId));
    }
    unawaited(provisioning.fetchLoudnessGain(next.recordingId));
    // Jen naplní `_artworkCache`/`_accentColorCache` -- stav mění, jen když
    // `nowPlaying` odpovídá, což tu ještě neplatí.
    unawaited(_resolveArtworkAndAccent(next));
  }

  /// Prostý `Timer`, žádná Hive/background persistence jako u Finampu --
  /// appka je jen webová/foreground, takže časovač stejně nepřežije zavření
  /// karty a nemá smysl ho ukládat. Poslední `sleepTimerFadeDuration` (nebo
  /// míň, u krátkých časovačů) se hlasitost lineárně ztlumí místo tvrdého
  /// zastavení -- `_sleepTimer` proto vyprší `fadeDuration` PŘED
  /// `sleepTimerEndAt`, ať fade doběhne přesně na uživatelem zvolený čas.
  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _cancelFade();
    state = state.withSleepTimerEndAt(DateTime.now().add(duration));
    final fadeDuration = duration < sleepTimerFadeDuration ? duration : sleepTimerFadeDuration;
    _sleepTimer = Timer(duration - fadeDuration, () => _fadeOutAndPause(fadeDuration));
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _cancelFade();
    state = state.withSleepTimerEndAt(null);
  }

  /// Lineárně ztlumí hlasitost přes `fadeDuration`, pak zastaví přehrávání a
  /// hlasitost vrátí na uživatelovu nastavenou hodnotu (`state.volume`) --
  /// bez vrácení by další/nová skladba po probuzení hrála potichu, aniž by
  /// o tom uživatel věděl.
  void _fadeOutAndPause(Duration fadeDuration) {
    _gainRampTimer?.cancel();
    _gainRampTimer = null;
    // Z EFEKTIVNÍ hlasitosti (vč. normalizace) -- ze `state.volume` by fade u
    // hlasité, normalizací ztlumené skladby nejdřív skočil nahoru.
    final originalVolume = _effectiveVolume;
    const stepInterval = Duration(milliseconds: 120);
    final steps = (fadeDuration.inMilliseconds / stepInterval.inMilliseconds).ceil().clamp(1, 1 << 30);
    var step = 0;
    _fadeTimer = Timer.periodic(stepInterval, (timer) async {
      step += 1;
      final t = (step / steps).clamp(0.0, 1.0);
      await _player.setVolume(originalVolume * (1 - t));
      if (t >= 1.0) {
        timer.cancel();
        _fadeTimer = null;
        await _player.pause();
        // Aktuální efektivní hlasitost, ne ta z začátku fadu -- během 10 s
        // mohla přeskočit skladba (jiná korekce normalizace).
        await _player.setVolume(_effectiveVolume);
        _realtime.playbackPause();
        state = state.withSleepTimerEndAt(null);
      }
    });
  }

  /// Zruší právě probíhající fade (uspávač zrušen uprostřed ztlumování) a
  /// hlasitost hned vrátí zpátky -- bez tohohle by zrušení uspávače nechalo
  /// přehrávání potichu, dokud by si toho uživatel nevšiml sám.
  void _cancelFade() {
    if (_fadeTimer == null) return;
    _fadeTimer!.cancel();
    _fadeTimer = null;
    unawaited(_player.setVolume(_effectiveVolume));
  }

  /// iOS Safari pustí zvuk jen v přímé reakci na klepnutí. U skladby, co se
  /// teprve stahuje (pár vteřin), "platnost" klepnutí vyprší dřív, než je
  /// soubor hotový, a pozdější `play()` Safari potichu odmítne -- skladba se
  /// po stažení sama nespustila (živě nahlášeno). Proto hned při klepnutí
  /// spustíme vteřinu ticha na TOMTÉŽ audio prvku: tím ho Safari "odemkne" a
  /// pozdější přepnutí na skutečnou skladbu (`_startStream`) už smí hrát.
  /// Musí proběhnout synchronně v obsluze klepnutí, před prvním `await`.
  void _primeAudioElement(String recordingId) {
    if (!kIsWeb) return;
    final known = _ref.read(provisioningControllerProvider)[recordingId];
    if (known?.status == 'AVAILABLE' && known?.streamUrl != null) return;
    _priming = true;
    unawaited(_player.setAudioSource(AudioSource.uri(_silenceUri)).then<void>((_) {}, onError: (Object _) {}));
    unawaited(_player.play().catchError((Object _) {}));
  }

  bool _priming = false;

  /// 1 s ticha, 8 kHz / 8 bit mono WAV jako data URI (~8 kB).
  static final Uri _silenceUri = () {
    const sampleRate = 8000;
    const samples = sampleRate;
    final bytes = BytesBuilder();
    void u32(int v) => bytes.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void u16(int v) => bytes.add([v & 0xff, (v >> 8) & 0xff]);
    bytes.add('RIFF'.codeUnits);
    u32(36 + samples);
    bytes.add('WAVEfmt '.codeUnits);
    u32(16);
    u16(1); // PCM
    u16(1); // mono
    u32(sampleRate);
    u32(sampleRate); // byte rate
    u16(1); // block align
    u16(8); // bits per sample
    bytes.add('data'.codeUnits);
    u32(samples);
    bytes.add(List<int>.filled(samples, 128)); // 8bit PCM ticho = 128
    return Uri.dataFromBytes(bytes.takeBytes(), mimeType: 'audio/wav');
  }();

  Future<void> _playAtIndex(int index) async {
    final info = state.queue[index];
    _primeAudioElement(info.recordingId);
    state = AudioPlayerState(
      nowPlaying: info,
      isPlaying: false,
      isBuffering: true,
      position: Duration.zero,
      duration: null,
      // Stejný důvod jako `playQueue` výš -- cache místo natvrdo `null`.
      accentColor: _accentColorCache[info.recordingId],
      queue: state.queue,
      queueIndex: index,
      // Skok v rámci stejné fronty (next/previous/reorder) beze změny zdroje.
      queueSourceLabel: state.queueSourceLabel,
      shuffleEnabled: state.shuffleEnabled,
      shuffleOrder: state.shuffleOrder,
      repeatMode: state.repeatMode,
      speed: state.speed,
      volume: state.volume,
      recentlyPlayed: state.recentlyPlayed,
      normalizationEnabled: state.normalizationEnabled,
      // Uspávač běží dál i přes přepnutí skladby -- bez tohohle by UI
      // odpočet zmizel, zatímco `_sleepTimer` by pořád tiše tikal.
      sleepTimerEndAt: state.sleepTimerEndAt,
    );
    await _playCurrent();
  }

  /// Než skladbu přehraje, ověří/spustí obstarání přes `ProvisioningController`
  /// (`POST /tracks/{id}/provision`, viz app/routes/provisioning.py):
  /// - `AVAILABLE` hned po zavolání (cache hit, HTTP 200) -> rovnou streamuje.
  /// - `FAILED` hned po zavolání (request na provision selhal) -> chyba do UI.
  /// - cokoliv jiného (`QUEUED`/`PENDING`/`RUNNING`, HTTP 202, cache miss) ->
  ///   zůstane v `isBuffering` a přihlásí se na `_provisioningSub`, který čeká
  ///   na `track.available`/`FAILED` z WS (viz `ProvisioningController._handleEvent`).
  Future<void> _playCurrent() async {
    final info = state.nowPlaying!;
    unawaited(_resolveArtworkAndAccent(info));
    _provisioningSub?.close();
    _provisioningSub = null;
    _awaitingProvisioning = false;

    final provisioning = _ref.read(provisioningControllerProvider.notifier);

    // Rychlá cesta bez síťového čekání: skladbu už známe jako stáhnutou
    // (typicky další ve frontě, připravená v 80 % předchozí -- viz
    // `_maybeWarmUpNext`). Na zamčeném iPhonu iOS nechá stránku běžet jen
    // dokud hraje zvuk; `await provision()` mezi koncem skladby a `play()`
    // udělal pauzu, iOS stránku uspal a další skladba se nespustila, i když
    // appka ukazovala, že hraje (živě nahlášeno). `setUrl`+`play()` proto
    // musí proběhnout hned v obsluze konce skladby; server se zeptá až potom.
    final known = _ref.read(provisioningControllerProvider)[info.recordingId];
    if (known != null && known.status == 'AVAILABLE' && known.streamUrl != null) {
      unawaited(_startStream(
        info,
        _ref.read(provisioningRepositoryProvider).streamUrl(info.recordingId),
        isProgressive: false,
      ));
      return;
    }

    // `interactive` -- tuhle skladbu uživatel chce slyšet TEĎ (prioritní
    // fronta + závod slskd/YouTube na backendu), na rozdíl od prefetche.
    await provisioning.provision(info.recordingId, interactive: true);
    if (state.nowPlaying?.recordingId != info.recordingId) return; // mezitím přeskočeno jinam

    final result = _ref.read(provisioningControllerProvider)[info.recordingId];
    // `streamUrl != null` (ne jen `isAvailable`) -- `track.streaming` z WS
    // (viz `TrackStreamingEvent`/backend `OnFileLocated`) nastaví `streamUrl`
    // dřív, než je soubor kompletně stažený, u slskd zdroje. `/stream`
    // endpoint v tu chvíli umí servírovat ještě rostoucí soubor
    // (`_tail_growing_file`), takže přehrávání může začít o hodně dřív, než
    // by čekání na plné `AVAILABLE` dovolilo.
    if (result != null && result.streamUrl != null) {
      // `result.streamUrl`/WS eventy nesou `stream_url_for()` z backendu --
      // záměrně jen relativní cestu (`/api/v1/tracks/{id}/stream`, viz
      // app/provisioning_service.py). Web appka a API běží každá na jiném
      // portu (dev: 5000 vs 8000), takže relativní cesta by se vyhodnotila
      // proti špatnému originu a stream by potichu spadl na 404 -- stavíme
      // si vlastní absolutní URL přes `ProvisioningRepository`
      // (`ApiClient.baseUrl`), stejně jako to dělal starší kód.
      await _startStream(
        info,
        _ref.read(provisioningRepositoryProvider).streamUrl(info.recordingId),
        isProgressive: !result.isAvailable,
      );
    } else if (result != null && result.isFailed) {
      state = state.copyWith(isBuffering: false, error: result.error ?? 'obstarání skladby selhalo');
    } else {
      // HTTP 202 -- soubor se teprve stahuje/frontí. `isBuffering` už je
      // `true` z playQueue/_playAtIndex, `ProvisioningController` navíc nese
      // stav a `pct` pro UI (viz `TrackTile`/`availability_badge.dart`).
      _awaitingProvisioning = true;
      _waitForAvailability(info);
    }
  }

  void _waitForAvailability(NowPlayingInfo info) {
    _provisioningSub = _ref.listen<Map<String, TrackProvisioningState>>(
      provisioningControllerProvider,
      (previous, next) {
        if (state.nowPlaying?.recordingId != info.recordingId) {
          _provisioningSub?.close();
          _provisioningSub = null;
          _awaitingProvisioning = false;
          return;
        }
        final result = next[info.recordingId];
        if (result == null) return;
        if (result.streamUrl != null) {
          _provisioningSub?.close();
          _provisioningSub = null;
          // Stejný důvod jako v `_playCurrent` -- vlastní absolutní URL, ne
          // backendova relativní `result.streamUrl`.
          unawaited(_startStream(
            info,
            _ref.read(provisioningRepositoryProvider).streamUrl(info.recordingId),
            isProgressive: !result.isAvailable,
          ));
        } else if (result.isFailed) {
          _provisioningSub?.close();
          _provisioningSub = null;
          _awaitingProvisioning = false;
          state = state.copyWith(isBuffering: false, error: result.error ?? 'obstarání skladby selhalo');
        }
      },
    );
  }

  /// `isProgressive`: `true` když `streamUrl` přišel z `track.streaming`
  /// (soubor se ještě stahuje přes slskd, viz `OnFileLocated`/
  /// `_tail_growing_file` v backendu), ne z finálního `track.available`.
  /// Rozlišení je klíčové pro `_handleStreamFailure` níž -- selhání na ještě
  /// nedokončeném souboru neznamená, že skladba nejde přehrát vůbec.
  Future<void> _startStream(NowPlayingInfo info, String streamUrl, {required bool isProgressive}) async {
    _priming = false;
    _awaitingProvisioning = false;
    _warmedUpAfter = null;
    // Korekci z cache (už stažené skladby ji dostaly rovnou v `provision()`)
    // nastavíme PŘED spuštěním, ať první vteřina nehraje nahlas a pak se
    // neztlumí. Neznámá korekce -> 1.0, `_loadGainFor` ji případně doplní.
    _trackGainFactor = _factorForGainDb(
      _ref.read(provisioningControllerProvider.notifier).loudnessGainFor(info.recordingId),
    );
    _applyVolume();
    try {
      // `play()` musí padnout do stejného synchronního běhu jako uživatelův
      // klik, jinak ho prohlížečová autoplay politika ztiší -- `setUrl` dělá
      // reálný síťový požadavek, takže na jeho dokončení nečekáme před
      // voláním `play()` (just_audio start přehrávání sám odloží, dokud
      // zdroj nenačte). `play()` ale může selhat asynchronně samo (typicky
      // "prohlížeč tenhle kodek/kontejner neumí dekódovat", zjistí se to
      // často až při skutečném přehrávání, ne při `setUrl`) -- bez vlastního
      // `catchError` by to byla jen nezachycená výjimka nikde neviditelná
      // v UI, ne chyba v `state.error`.
      final durationFuture = _player.setUrl(streamUrl);
      unawaited(_player.play().catchError((Object e) {
        debugPrint('AudioPlayerController: play() selhalo pro ${info.recordingId}: $e');
        _handleStreamFailure(info, e, isProgressive: isProgressive);
      }));
      await durationFuture;
      // `setUrl` znovu načte celý zdroj -- pro jistotu znovu vynutíme
      // rychlost/hlasitost z předchozí skladby, ať se novým zdrojem
      // nevrátí na výchozí hodnoty.
      await _player.setSpeed(state.speed);
      _applyVolume();
      _realtime.playbackPlay(info.recordingId);
      _recordRecentlyPlayed(info);
      _beginScrobble(info.recordingId);
      if (_ref.read(provisioningControllerProvider.notifier).loudnessGainFor(info.recordingId) == null) {
        unawaited(_loadGainFor(info.recordingId));
      }
    } catch (e) {
      debugPrint('AudioPlayerController: setUrl() selhalo pro ${info.recordingId}: $e');
      _handleStreamFailure(info, e, isProgressive: isProgressive);
    }
  }

  /// Selhání přehrání z ještě NEDOKONČENÉHO stažení (`isProgressive`) se
  /// nebere jako definitivní chyba -- slskd stahování běžně spadne uprostřed
  /// (živě pozorováno: napíše pár bajtů, pak selže) a `CompositeProvider` na
  /// pozadí mezitím zkouší YouTube zálohu, která za pár vteřin uspěje. Bez
  /// týhle větve by uživatel viděl "Nepodařilo se přehrát" těsně před tím,
  /// než appka sama dorazí ke skutečnému výsledku -- místo toho se znovu
  /// přihlásíme na `_waitForAvailability` a počkáme na reálný výsledek
  /// (úspěch odjinud, nebo definitivní `FAILED`, až selžou všichni).
  /// Selhání finálního `track.available` (ne `isProgressive`) je naopak
  /// opravdu konec -- tam už není na co čekat.
  void _handleStreamFailure(NowPlayingInfo info, Object error, {required bool isProgressive}) {
    if (state.nowPlaying?.recordingId != info.recordingId) return;
    if (isProgressive) {
      _awaitingProvisioning = true;
      state = state.copyWith(isBuffering: true);
      _waitForAvailability(info);
      return;
    }
    state = state.copyWith(isBuffering: false, error: '$error');
  }

  /// Zapíše skladbu do `AudioPlayerState.recentlyPlayed` -- volané až tady
  /// (ne v `playQueue`/`_playAtIndex`), aby se do historie nedostaly
  /// pokusy, co skončí chybou dřív, než `setUrl` vůbec doběhne. Nejnovější
  /// první, bez duplicit, omezeno na posledních 20 -- delší historie nemá
  /// pro "bublinovou" řadu na Home smysl.
  void _recordRecentlyPlayed(NowPlayingInfo info) {
    final updated = [info, ...state.recentlyPlayed.where((r) => r.recordingId != info.recordingId)];
    state = state.copyWith(recentlyPlayed: updated.take(20).toList());
  }

  /// Vibrantní/dominantní barva obalu pro "PixelPlay" dynamické zabarvení UI
  /// (viz `AudioPlayerState.accentColor`, extrakce sdílená s
  /// `theme/accent_color.dart` pro per-obrazovkové barvení Release/Artist).
  /// Kontroluje `recordingId` proti aktuálnímu stavu, aby pozdě doběhnuvší
  /// extrakce ze staré skladby nepřepsala barvu té, na kterou uživatel
  /// mezitím přepnul.
  Future<void> _extractAccentColor(String recordingId, String artworkUrl) async {
    final color = await extractAccentColor(artworkUrl);
    if (color == null) return;
    _accentColorCache[recordingId] = color;
    if (state.nowPlaying?.recordingId == recordingId) {
      state = state.copyWith(accentColor: color);
    }
  }

  /// Doplní chybějící obal/barvu pro `nowPlaying`. `NowPlayingInfo.artworkUrl`
  /// je `null` napevno u sourozenců ve frontě, kterým volající neposlal
  /// `albumArtUrl` (Domů/Knihovna/Oblíbené/playlisty -- na rozdíl od
  /// Release/Artist obrazovek, co ho znají a pošlou) -- bez tohohle
  /// `PlayerBar`/`NowPlayingScreen` při skoku na takovou skladbu (next/
  /// previous/swipe) ukázaly prázdný obal a natvrdo výchozí (fialovou)
  /// barvu, protože `_extractAccentColor` se dřív volalo jen
  /// `if (info.artworkUrl != null)`. Dohledá ho stejným zdrojem jako
  /// `TrackTile.build` (`recordingArtworkProvider` z `releaseId`/`artistId`)
  /// a zapíše zpátky do `nowPlaying`/fronty, ať UI nemusí mít vlastní
  /// fallback logiku navíc.
  Future<void> _resolveArtworkAndAccent(NowPlayingInfo info) async {
    var artworkUrl = info.artworkUrl ?? _artworkCache[info.recordingId];
    if (artworkUrl == null && (info.releaseId != null || info.artistId != null)) {
      artworkUrl = await _ref.read(
        recordingArtworkProvider((releaseId: info.releaseId, artistId: info.artistId)).future,
      );
    }
    if (artworkUrl == null) return;
    _artworkCache[info.recordingId] = artworkUrl;

    if (info.artworkUrl == null && state.nowPlaying?.recordingId == info.recordingId) {
      final updatedInfo = NowPlayingInfo(
        recordingId: info.recordingId,
        title: info.title,
        artistName: info.artistName,
        artistId: info.artistId,
        releaseId: info.releaseId,
        artworkUrl: artworkUrl,
      );
      final queueIndex = state.queue.indexWhere((i) => i.recordingId == info.recordingId);
      state = state.copyWith(
        nowPlaying: updatedInfo,
        queue: queueIndex == -1 ? state.queue : ([...state.queue]..[queueIndex] = updatedInfo),
      );
    }

    final cachedColor = _accentColorCache[info.recordingId];
    if (cachedColor != null) {
      if (state.nowPlaying?.recordingId == info.recordingId) {
        state = state.copyWith(accentColor: cachedColor);
      }
    } else {
      await _extractAccentColor(info.recordingId, artworkUrl);
    }
  }

  Future<void> togglePlayPause() async {
    if (state.nowPlaying == null) return;
    if (_player.playing) {
      await _player.pause();
      _realtime.playbackPause();
    } else {
      await _player.play();
      _realtime.playbackPlay(state.nowPlaying!.recordingId, positionMs: state.position.inMilliseconds);
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _realtime.playbackSeek(position.inMilliseconds);
    _mediaSession.setPosition(position: position, duration: state.duration, speed: state.speed);
  }

  void _onPlayerStateChanged(PlayerState playerState) {
    if (_priming) {
      // Stav tichého "odemykacího" zvuku není stav skladby -- UI dál ukazuje
      // načítání a jeho konec nesmí spustit `next()`.
      state = state.copyWith(isPlaying: false, isBuffering: true);
      return;
    }
    state = state.copyWith(
      isPlaying: playerState.playing,
      isBuffering: _awaitingProvisioning ||
          playerState.processingState == ProcessingState.loading ||
          playerState.processingState == ProcessingState.buffering,
    );
    if (playerState.processingState == ProcessingState.completed) {
      if (state.repeatMode == RepeatMode.one) {
        unawaited(_replayCurrent());
      } else {
        unawaited(next());
      }
    }
  }

  // --- Scrobbling (poslechy pro osobní mixy + ListenBrainz) ---------------

  String? _scrobbleId;
  DateTime? _scrobbleStartedAt;
  Duration _scrobbleAccum = Duration.zero;
  Duration? _scrobbleLastPos;
  bool _scrobbled = false;

  /// Nové přehrávání skladby (i opakované přehrání téže) = nový poslech.
  void _beginScrobble(String recordingId) {
    _scrobbleId = recordingId;
    _scrobbleStartedAt = DateTime.now();
    _scrobbleAccum = Duration.zero;
    _scrobbleLastPos = null;
    _scrobbled = false;
    unawaited(_ref.read(listensRepositoryProvider).playingNow(recordingId).catchError((Object _) {}));
  }

  /// Počítá jen skutečně odehraný čas (posun vpřed přes seek se nepočítá).
  /// Poslech se nahlásí po polovině délky nebo 4 minutách -- standardní
  /// pravidlo ListenBrainz/Last.fm; skladby kratší než 30 s se nehlásí.
  void _trackScrobble(Duration position) {
    final id = _scrobbleId;
    if (id == null || _scrobbled || state.nowPlaying?.recordingId != id) return;
    final last = _scrobbleLastPos;
    _scrobbleLastPos = position;
    if (last == null || !_player.playing) return;
    final delta = position - last;
    if (delta <= Duration.zero || delta > const Duration(seconds: 3)) return;
    _scrobbleAccum += delta;
    final duration = state.duration;
    if (duration != null && duration < const Duration(seconds: 30)) return;
    final half = duration == null ? const Duration(minutes: 4) : duration ~/ 2;
    final threshold = half < const Duration(minutes: 4) ? half : const Duration(minutes: 4);
    if (_scrobbleAccum < threshold) return;
    _scrobbled = true;
    unawaited(_ref
        .read(listensRepositoryProvider)
        .submitListen(
          recordingId: id,
          playedAt: _scrobbleStartedAt ?? DateTime.now(),
          played: _scrobbleAccum,
          source: state.queueSourceLabel,
        )
        .catchError((Object e) => debugPrint('AudioPlayerController: poslech se nepodařilo nahlásit: $e')));
  }

  Future<void> _replayCurrent() async {
    final current = state.nowPlaying;
    if (current != null) _beginScrobble(current.recordingId);
    await _player.seek(Duration.zero);
    await _player.play();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _fadeTimer?.cancel();
    _gainRampTimer?.cancel();
    _provisioningSub?.close();
    _player.dispose();
    super.dispose();
  }
}

final audioPlayerControllerProvider = StateNotifierProvider<AudioPlayerController, AudioPlayerState>((ref) {
  return AudioPlayerController(ref.watch(realtimeClientProvider), ref);
});
