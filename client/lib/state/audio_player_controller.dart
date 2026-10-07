import '../routing/branches.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random, pow;
import 'dart:typed_data' show BytesBuilder;

import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
// Flutter má od 3.47 vlastní `RepeatMode` (`RepeatingAnimationBuilder`) --
// skrytý, ať nekoliduje s naším (viz níže).
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart' show ImperativeRouteMatch;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart' show ApiException;
import '../core/device_token.dart' show authHeaders, withDeviceToken;
import '../core/diagnostics.dart' show diagReport;
import '../core/prefetch_cache.dart';
import '../core/media_session.dart';
import '../core/profile_prefs.dart';
import '../core/radio_mode.dart';
import '../core/ws_client.dart';
import '../models/playback_model.dart' show RepeatMode;
import '../routing/app_router.dart';
import '../theme/accent_color.dart';
import 'artwork_provider.dart';
import 'auth_controller.dart' show profilePrefsReady;
import '../core/now_playing_activity.dart';
import 'provisioning_controller.dart';
import 'collection_progress.dart';
import 'offline_controller.dart';
import 'providers.dart';
import 'heard_controller.dart';

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
    this.groupId,
    this.groupLabel,
    this.durationMs,
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

  /// Blok ve frontě: skladby přidané najednou (album/playlist přes "Přehrát
  /// jako další" / "Přidat do fronty") -- ve frontě se ukazují a odebírají
  /// jako celek, ne po jedné (živě chtěné: "nechci mazat 50 skladeb").
  final String? groupId;
  final String? groupLabel;

  /// Délka z katalogu -- ukáže se, než přehrávač zná skutečnou (po obnovení
  /// stránky bylo „1:20 / 0:00“).
  final int? durationMs;

  NowPlayingInfo withGroup(String? id, String? label) => NowPlayingInfo(
        recordingId: recordingId,
        title: title,
        artistName: artistName,
        artistId: artistId,
        releaseId: releaseId,
        artworkUrl: artworkUrl,
        groupId: id,
        groupLabel: label,
        durationMs: durationMs,
      );
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

  /// Délka pro zobrazení: skutečná z přehrávače, jinak z katalogu.
  Duration? get shownDuration =>
      duration ?? (nowPlaying?.durationMs != null ? Duration(milliseconds: nowPlaying!.durationMs!) : null);
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
    bool clearError = false,
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
      // `AudioPlayerState`, ne přes `copyWith` (nebo `clearError`).
      error: clearError ? null : (error ?? this.error),
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
    unawaited(_restoreSession());
    addListener(_maybePersistSession, fireImmediately: false);
    _player.playerStateStream.listen(_onPlayerStateChanged);
    _player.positionStream.listen((position) {
      if (_priming) return;
      _maybeRecordStart(position);
      if (_radioActive) {
        _radioLastRaw = position;
        _radioLastRawAt = DateTime.now();
        _onRadioPosition(position, measured: true);
        return;
      }
      state = state.copyWith(position: position);
      _maybeReleaseAutoRetry(position);
      _maybeWarmUpNext(position);
      _trackScrobble(position);
      if (_player.playing) _maybeSaveSpokenProgress();
      if (_maybeLoopAb(position)) return;
      _maybeAdvanceEarly(position);
    });
    _player.durationStream.listen((duration) {
      if (_priming || _radioActive) return; // délku v rádiu dává časová osa
      state = state.copyWith(duration: duration);
    });
    // Chyby uprostřed přehrávání (výpadek sítě, restart serveru) chodí jen
    // sem -- dřív je nikdo neposlouchal a appka "hrála" se stojící pozicí.
    _player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace _) {
      final info = state.nowPlaying;
      if (info == null || _priming || _radioActive || _awaitingProvisioning) return;
      if (_readyGen != _sourceGen) return; // chyba staršího / ještě se načítajícího zdroje
      _handleStreamFailure(info, e, isProgressive: _currentProgressive);
    });
    _installMediaHandlers();
    addListener(_syncMediaSession, fireImmediately: false);
    _ref.listen<AbRepeat?>(abRepeatProvider, _onAbChanged);
    // Po návratu do appky dopočítat barvu skladby, pokud se na pozadí
    // nespočítala (viz `_refreshAccentIfMissing`).
    // Odchod z appky (zamčení, přepnutí, ukončení): uložit přesnou pozici
    // hned -- jinak mohla být až 5 s stará (nebo před posledním přetočením).
    _lifecycle = AppLifecycleListener(
      onResume: _refreshAccentIfMissing,
      onShow: _refreshAccentIfMissing,
      onHide: () {
        _maybePersistSession(state, force: true);
        _maybeSaveSpokenProgress(force: true);
      },
      onPause: () => _maybePersistSession(state, force: true),
    );
    _stallWatch = Timer.periodic(const Duration(seconds: 3), (_) => _checkStall());
  }

  // --- Tiché zaseknutí -----------------------------------------------------
  //
  // Spojení spadne uprostřed stahování dalšího kusu (přepnutí Wi-Fi <-> data)
  // a iOS přehrávač jen čeká: hlásí "hraje", pozice stojí, chyba nepřijde
  // (živě: I Hate It Here se zasekla po přepnutí sítě). Stojí-li pozice
  // hrající skladby ze serveru déle než `_stallLimit`, navázat od stejného
  // místa jako po chybě (`_handleStreamFailure` -- sám jednou, pak chyba se
  // "Zkusit znovu", nezacyklí se). Rádio a stahující se soubor mají hlídání
  // vlastní.
  static const _stallLimit = Duration(seconds: 12);
  Timer? _stallWatch;
  Duration _stallPosition = Duration.zero;
  DateTime _stallSince = DateTime.now();

  void _checkStall() {
    final info = state.nowPlaying;
    final now = DateTime.now();
    final position = _player.position;
    final processing = _player.processingState;
    final watched = info != null &&
        _player.playing &&
        !_radioActive &&
        !_priming &&
        !_awaitingProvisioning &&
        !_currentProgressive &&
        !_currentLocal &&
        processing != ProcessingState.completed &&
        processing != ProcessingState.idle;
    if (!watched || position != _stallPosition) {
      _stallPosition = position;
      _stallSince = now;
      return;
    }
    if (now.difference(_stallSince) < _stallLimit) return;
    _stallSince = now;
    debugPrint('AudioPlayerController: pozice stojí ${_stallLimit.inSeconds} s ($processing), navazuji');
    _handleStreamFailure(info, 'zaseknuté přehrávání', isProgressive: false);
  }

  final MediaSessionBridge _mediaSession = MediaSessionBridge();

  // --- Zapamatování přehrávače mezi spuštěními appky ------------------------
  //
  // Po zavření a znovuotevření se přehrávač obnoví tam, kde se skončilo
  // (fronta, skladba, pozice, shuffle/opakování) -- pozastavený; iOS webové
  // appce nedovolí se po otevření sama rozehrát, play naváže od pozice.

  final _prefsGeneration = profilePrefsGeneration;
  static const _sessionPrefKey = 'player.session.v1';
  static const _sessionQueuePrefKey = 'player.session.queue.v1';
  bool _restoredIdle = false;
  Duration? _resumeAt;
  String? _resumeFor;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastPersistKey;

  Duration? _takeResume(NowPlayingInfo info) {
    if (_resumeFor != info.recordingId) return null;
    final at = _resumeAt;
    _resumeAt = null;
    _resumeFor = null;
    return at;
  }

  static Map<String, dynamic> _infoToJson(NowPlayingInfo i) => {
        'id': i.recordingId,
        't': i.title,
        if (i.artistName != null) 'a': i.artistName,
        if (i.artistId != null) 'ai': i.artistId,
        if (i.releaseId != null) 'r': i.releaseId,
        if (i.artworkUrl != null) 'art': i.artworkUrl,
        if (i.groupId != null) 'g': i.groupId,
        if (i.groupLabel != null) 'gl': i.groupLabel,
        if (i.durationMs != null) 'd': i.durationMs,
      };

  static NowPlayingInfo _infoFromJson(Map<String, dynamic> j) => NowPlayingInfo(
        recordingId: j['id'] as String,
        title: j['t'] as String,
        artistName: j['a'] as String?,
        artistId: j['ai'] as String?,
        releaseId: j['r'] as String?,
        artworkUrl: j['art'] as String?,
        groupId: j['g'] as String?,
        groupLabel: j['gl'] as String?,
        durationMs: (j['d'] as num?)?.toInt(),
      );

  /// Rozposlouchané album/playlist (ne náhodně, ne jedna skladba) -- detail
  /// pak nabídne "Pokračovat". Pozice po 5 s jako relace.
  bool _rememberProgress = true;

  void _recordCollectionProgress(AudioPlayerState s) {
    if (!_rememberProgress) return;
    final route = _queueContext;
    final np = s.nowPlaying;
    if (np == null || !CollectionProgressController.isCollection(route) || s.shuffleEnabled || s.queue.length < 2) {
      return;
    }
    _ref.read(collectionProgressProvider.notifier).record(route!, (
      recordingId: np.recordingId,
      title: np.title,
      index: s.queueIndex,
      total: s.queue.length,
      positionMs: s.position.inMilliseconds,
      deviceId: null,
      updatedAt: null,
    ));
  }

  /// Uloží stav: hned při změně skladby/fronty, pozici nejvýš jednou za 5 s.
  List<NowPlayingInfo>? _encodedQueueFor;
  String _encodedQueue = '[]';

  void _maybePersistSession(AudioPlayerState s, {bool force = false}) {
    final np = s.nowPlaying;
    // Po přepnutí profilu / odhlášení (do restartu appky) nepsat starou
    // frontu zpátky -- obnovil by ji další profil.
    if (np == null || _restoredIdle || _prefsGeneration != profilePrefsGeneration) return;
    final key = '${np.recordingId}|${s.queueIndex}|${s.queue.length}|${s.shuffleEnabled}|${s.repeatMode.name}';
    final now = DateTime.now();
    if (!force && key == _lastPersistKey && now.difference(_lastPersist) < const Duration(seconds: 5)) return;
    // Až za omezením (dřív se pokrok alba ukládal na disk ~5x za vteřinu).
    _recordCollectionProgress(s);
    _lastPersistKey = key;
    _lastPersist = now;
    // Frontu (klidně tisíce skladeb, stovky kB) zakódovat A ZAPSAT jen když
    // se změnila -- dřív se celá přepisovala každých 5 s po celou dobu hraní
    // (Android přepisuje celý XML, web localStorage synchronně).
    final queueChanged = !identical(s.queue, _encodedQueueFor);
    if (queueChanged) {
      _encodedQueueFor = s.queue;
      _encodedQueue = jsonEncode([for (final q in s.queue) _infoToJson(q)]);
    }
    final queueJson = _encodedQueue;
    final data = jsonEncode({
      'index': s.queueIndex,
      'positionMs': s.position.inMilliseconds,
      'source': s.queueSourceLabel,
      'context': _queueContext,
      'shuffle': s.shuffleEnabled,
      'shuffleOrder': s.shuffleOrder,
      'repeat': s.repeatMode.name,
    });
    unawaited(SharedPreferences.getInstance().then((p) async {
      if (queueChanged) await p.setString(_sessionQueuePrefKey, queueJson);
      await p.setString(_sessionPrefKey, data);
    }).then<void>(
      (_) {},
      onError: (Object _) {},
    ));
  }

  Future<void> _restoreSession() async {
    try {
      // Až po `/auth/me` -- cizí uloženou relaci (jiný profil) mezitím smaže.
      await profilePrefsReady(_ref);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionPrefKey);
      if (raw == null || !mounted || state.nowPlaying != null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      // Fronta zvlášť (nový formát); starý měl frontu přímo uvnitř.
      final rawQueue = j['queue'] ?? jsonDecode(prefs.getString(_sessionQueuePrefKey) ?? '[]');
      final queue = [for (final e in (rawQueue as List<dynamic>)) _infoFromJson(e as Map<String, dynamic>)];
      if (queue.isEmpty) return;
      final index = (j['index'] as int).clamp(0, queue.length - 1);
      _queueContext = j['context'] as String?;
      state = state.copyWith(
        nowPlaying: queue[index],
        queue: queue,
        queueIndex: index,
        position: Duration(milliseconds: j['positionMs'] as int? ?? 0),
        queueSourceLabel: j['source'] as String?,
        shuffleEnabled: j['shuffle'] as bool? ?? false,
        shuffleOrder: (j['shuffleOrder'] as List<dynamic>?)?.cast<int>(),
        repeatMode: RepeatMode.values.firstWhere((m) => m.name == j['repeat'], orElse: () => RepeatMode.off),
        isPlaying: false,
        isBuffering: false,
      );
      _restoredIdle = true;
      unawaited(_resolveArtworkAndAccent(queue[index]));
    } catch (e) {
      debugPrint('AudioPlayerController: obnova přehrávače selhala: $e');
    }
  }

  /// Tlačítka zamykací obrazovky. Znovu i po spuštění rádia -- Safari je při
  /// změně zdroje (živý stream) přepíše na ±10 s.
  void _installMediaHandlers() {
    _mediaSession.setHandlers(
      onPlay: () => unawaited(_setPlaying(true)),
      onPause: () => unawaited(_setPlaying(false)),
      onNext: () => unawaited(next()),
      onPrevious: () => unawaited(previous()),
      onSeek: (position) => unawaited(seek(position)),
    );
  }

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
      _syncLiveActivity(s);
      return;
    }
    final key = '${info.recordingId}|${info.artworkUrl}|${info.artistName}';
    if (key != _mediaSessionKey) {
      _mediaSessionKey = key;
      _activityArt = info.artworkUrl;
      _mediaSession.setMetadata(
        title: info.title,
        artist: info.artistName,
        album: s.queueSourceLabel,
        artworkUrl: info.artworkUrl,
      );
      // Skladby z fronty obal často nenesou (přehrávač si ho dohledává přes
      // recordingArtworkProvider) -- na zamčené obrazovce pak u další
      // skladby obrázek chyběl (živě nahlášeno). Dohledat stejně a poslat.
      if (info.artworkUrl == null && (info.releaseId != null || info.artistId != null)) {
        final requested = key;
        final provider = recordingArtworkProvider((releaseId: info.releaseId, artistId: info.artistId));
        // Poslech drží autoDispose provider naživu, dokud se obal nenačte.
        final keepAlive = _ref.listen<AsyncValue<String?>>(provider, (_, __) {});
        unawaited(_ref.read(provider.future).then((url) {
          if (url == null || _mediaSessionKey != requested) return;
          _activityArt = url;
          _syncLiveActivity(state);
          _mediaSession.setMetadata(
            title: info.title,
            artist: info.artistName,
            album: s.queueSourceLabel,
            artworkUrl: url,
          );
        }).catchError((Object _) {}).whenComplete(keepAlive.close));
      }
    }
    if (s.isPlaying != _mediaSessionPlaying || s.duration != _mediaSessionDuration) {
      _mediaSessionPlaying = s.isPlaying;
      _mediaSessionDuration = s.duration;
      _mediaSession.setPlaying(s.isPlaying);
      _mediaSession.setPosition(position: s.position, duration: s.duration, speed: s.speed);
    }
    _syncLiveActivity(s);
  }

  String? _activityArt;
  String? _activityKey;

  /// Live Activity (iOS): stejný stav jako zamčená obrazovka + barva skladby;
  /// posílá se jen při změně (skladba, obal, play/pauza, barva).
  void _syncLiveActivity(AudioPlayerState s) {
    final info = s.nowPlaying;
    if (info == null) {
      if (_activityKey != null) unawaited(NowPlayingActivity.end());
      _activityKey = null;
      return;
    }
    final key = '${info.recordingId}|$_activityArt|${s.isPlaying}|${s.accentColor?.toARGB32()}';
    if (key == _activityKey) return;
    _activityKey = key;
    unawaited(NowPlayingActivity.update(
      recordingId: info.recordingId,
      title: info.title,
      artist: info.artistName ?? '',
      artworkUrl: _activityArt,
      color: s.accentColor ?? const Color(0xFF6B3FD6),
      playing: s.isPlaying,
    ));
  }

  Future<void> _setPlaying(bool playing) async {
    if (state.nowPlaying == null) return;
    if (_deferWhileLoading(play: playing)) return;
    // Po konečné chybě (i z rádia) Play ze zámku/sluchátek zkusí znovu.
    if (playing && state.error != null) return retryCurrent();
    if (_player.playing == playing) return;
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

  /// Pauza (zamčená obrazovka, sluchátka, Connect, předání jinam, Shazam)
  /// přišla, když skladba ještě nebyla připravená -- dřív se zahodila a
  /// skladba se po stažení sama rozehrála (po předání pak hrála obě
  /// zařízení). `_startStream` zdroj jen načte a nechá ho pozastavený.
  bool _startPausedWhenReady = false;

  /// Skladba se obstarává / hraje tiché odemknutí -- `_player` teď nesmí
  /// dostat pauzu (na webu by tím pozastavil tichý prvek a stream by se
  /// pak nespustil, viz `_primeAudioElement`).
  bool get _loadingTrack => _awaitingProvisioning || _priming;

  /// Pauza/play během načítání jen jako záměr; `true` = vyřízeno.
  bool _deferWhileLoading({required bool play}) {
    if (!_loadingTrack) return false;
    _startPausedWhenReady = !play;
    return true;
  }

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
  // --- Nepřetržitý stream fronty ("rádio", iOS) ----------------------------
  //
  // Na zamčeném iPhonu webová appka nesmí spustit nový zdroj zvuku -- další
  // skladba "hrála" potichu, dokud se appka neotevřela (živě nahlášeno).
  // V rádiu se `<audio>` připojí JEDNOU na stream ze serveru (backend
  // app/radio.py), do kterého server skladby řadí za sebou; zdroj se nemění.
  // Podle časové osy (kde ve streamu která skladba začíná) se tady přepíná
  // `nowPlaying`, pozice a délka. Posun/přeskočení = nový stream od daného
  // místa (to je vždy přímo po klepnutí, takže ho iOS pustí).

  /// Výchozí: zapnuto na iPhonu/iPadu; uživatel ho v menu přehrávače může
  /// vypnout (uloženo per zařízení).
  bool _radioMode = shouldUseRadioStream();
  static const _radioPrefKey = 'player.radio_mode';

  bool get radioModeEnabled => _radioMode;

  Future<void> setRadioMode(bool enabled) async {
    _radioMode = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_radioPrefKey, enabled);
    } catch (_) {}
    // Projeví se od dalšího spuštění skladby (běžící stream nepřerušujeme).
  }

  String? _radioSession;
  List<_RadioSegment> _radioTimeline = const [];
  Timer? _radioPoll;
  Duration? _radioStartPosition;
  DateTime _radioLastRestart = DateTime.fromMillisecondsSinceEpoch(0);

  // Hlídač rádia: "hraje", ale pozice streamu stojí (Safari dohrál zastaralý
  // playlist a čeká) -> nový stream. Živě: po 2 h pauzy spuštění ze
  // zamčené obrazovky přehrálo 5 s a stálo, pozice 5378 ms 15 minut.
  Duration? _radioStallRaw;

  /// Lhůta na rozběh nového streamu (pozice 0): 15 s, po každém neúspěšném
  /// restartu dvojnásobek až do 60 s; po rozjetí zpátky na 15 s.
  static const _radioStartGraceMin = Duration(seconds: 15);
  static const _radioStartGraceMax = Duration(seconds: 60);
  Duration _radioStartGrace = _radioStartGraceMin;

  /// Appka na obrazovce (ne zamčený telefon / pozadí). Jen tehdy smí rádio
  /// navázat novým streamem -- iOS jinak nový zdroj zvuku zablokuje.
  bool get _appVisible {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return pageVisible() && (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }
  DateTime _radioStallSince = DateTime.now();
  DateTime? _radioPausedAt;
  Timer? _radioTick;
  Duration _radioLastRaw = Duration.zero;
  DateTime _radioLastRawAt = DateTime.now();

  bool get _radioActive => _radioSession != null;
  final bool _nativeHls = supportsNativeHls();

  /// Pořadí dalších skladeb po té aktuální (indexy do fronty) -- stejná
  /// logika jako `nextIndex`, jen dopředu celá (shuffle, opakování).
  List<int> _upcomingOrder() {
    final s = state;
    if (s.queue.isEmpty) return const [];
    if (s.repeatMode == RepeatMode.one) return List.filled(30, s.queueIndex);
    List<int> order;
    if (s.shuffleEnabled && s.shuffleOrder != null) {
      final pos = s.shuffleOrder!.indexOf(s.queueIndex);
      order = pos < 0 ? <int>[] : s.shuffleOrder!.sublist(pos + 1);
      if (s.repeatMode == RepeatMode.all) order = [...order, ...s.shuffleOrder!, ...s.shuffleOrder!];
    } else {
      order = [for (var i = s.queueIndex + 1; i < s.queue.length; i++) i];
      if (s.repeatMode == RepeatMode.all) {
        order = [
          ...order,
          for (var r = 0; r < 2; r++)
            for (var i = 0; i < s.queue.length; i++) i,
        ];
      }
    }
    return order.take(300).toList();
  }

  static String _randomHex() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Založí relaci (souběžně -- id volí klient, stream může začít hned v
  /// obsluze klepnutí) a vrátí URL streamu.
  String _startRadio(NowPlayingInfo info, Duration position) {
    final sid = _randomHex();
    _radioSession = sid;
    _radioTimeline = const [];
    _radioStartPosition = position;
    final api = _ref.read(apiClientProvider);
    final ids = [info.recordingId, for (final i in _upcomingOrder()) state.queue[i].recordingId];
    // A-B opakování této skladby -> smyčku plynule vyrábí server.
    final ab = _ref.read(abRepeatProvider);
    final abActive = ab != null && ab.recordingId == info.recordingId && ab.b != null;
    // Úpravy fronty (`_radioSyncUpcoming`) se řetězí ZA založení relace --
    // jinak by rychlé přidání do fronty mohlo dorazit dřív a ztratit se.
    _radioSync = api.putJson('/radio/$sid', body: {
      'recordingIds': ids,
      'positionMs': position.inMilliseconds,
      if (abActive) 'abStartMs': ab.a.inMilliseconds,
      if (abActive) 'abEndMs': ab.b!.inMilliseconds,
    }).then<void>((_) {}, onError: (Object e) => debugPrint('AudioPlayerController: rádio se nezaložilo: $e'));
    _radioPoll?.cancel();
    _radioPoll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollRadio()));
    // Plynulá pozice: Safari u HLS hlásí `currentTime` jen po kouskách, tečka
    // na vlnovce skákala (živě nahlášeno) -- mezi hlášeními dopočítat.
    _radioLastRaw = Duration.zero;
    _radioLastRawAt = DateTime.now();
    _radioTick?.cancel();
    _radioTick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_radioActive || !_player.playing || _loadingTrack) return;
      final since = DateTime.now().difference(_radioLastRawAt);
      if (since > const Duration(seconds: 3)) return; // hlášení nechodí -> nehádat
      _onRadioPosition(_radioLastRaw + since * state.speed);
    });
    // Safari: HLS (stahuje ho systémový přehrávač i na pozadí); jinde MP3.
    return _nativeHls ? '${api.baseUrl}/radio/$sid/index.m3u8' : '${api.baseUrl}/radio/$sid/stream';
  }

  void _stopRadio() {
    _radioSession = null;
    _radioTimeline = const [];
    _radioPoll?.cancel();
    _radioPoll = null;
    _radioTick?.cancel();
    _radioTick = null;
  }

  /// Nový stream od `position` aktuální skladby (posun, obnovení po pauze).
  void _restartRadio(Duration position) {
    final info = state.nowPlaying;
    if (info == null) return;
    _radioPausedAt = null;
    _radioStallRaw = null;
    // Nový zdroj: přerušený `setUrl` z `_startStream` (restart dřív, než
    // první stream doběhl) jinak hlásil falešné "Nepodařilo se přehrát".
    final gen = ++_sourceGen;
    // Čekání na automatický druhý pokus (`_handleStreamFailure`) tím končí.
    _awaitingProvisioning = false;
    final url = _startRadio(info, position);
    state = state.copyWith(position: position, clearError: true);
    unawaited(_player.setUrl(url).then<void>((_) {
      _installMediaHandlers();
      if (gen != _sourceGen) return;
      _readyGen = gen;
      // Přerušený `_startStream` start neoznámil (historie, poslech).
      final pending = _unannounced;
      if (pending != null && pending.recordingId == state.nowPlaying?.recordingId) {
        _announceStart(pending, paused: false, resumedAt: _unannouncedResume);
      }
    }, onError: (Object e) => debugPrint('rádio setUrl: $e')));
    unawaited(_player.play().catchError((Object e) => debugPrint('rádio play: $e')));
  }

  Future<void> _pollRadio() async {
    final sid = _radioSession;
    if (sid == null || !_player.playing) return;
    final raw = _player.position;
    final now = DateTime.now();
    if (!_appVisible) {
      _radioStallRaw = null; // na pozadí nový stream nejde (iOS) -- nehlídat
    } else if (raw == _radioStallRaw) {
      // I pozice 0: nový stream po výpadku/restartu serveru se nenačetl a
      // UI ukazovalo "hraje" v tichu. Na start dát víc času.
      final limit = raw > Duration.zero ? const Duration(seconds: 8) : _radioStartGrace;
      if (now.difference(_radioStallSince) > limit &&
          now.difference(_radioLastRestart) > const Duration(seconds: 15)) {
        debugPrint('AudioPlayerController: rádio stojí na $raw, navazuji novým streamem');
        _radioLastRestart = now;
        // Pomalý start (server dlouho skládá první kus): restart po pevných
        // 15 s by ho pokaždé utnul a nikdy nedoběhl -- příště čekat déle.
        if (raw == Duration.zero) {
          final longer = _radioStartGrace * 2;
          _radioStartGrace = longer > _radioStartGraceMax ? _radioStartGraceMax : longer;
        }
        _restartRadio(state.position);
        return;
      }
    } else {
      _radioStallRaw = raw;
      _radioStallSince = now;
      if (raw > Duration.zero) _radioStartGrace = _radioStartGraceMin; // rozjelo se
    }
    try {
      final json = await _ref
          .read(apiClientProvider)
          .getJson('/radio/$sid/timeline', query: {'playedMs': _player.position.inMilliseconds.toString()});
      if (_radioSession != sid) return;
      _radioTimeline = [
        for (final e in (json['segments'] as List<dynamic>).cast<Map<String, dynamic>>())
          _RadioSegment(
            recordingId: e['recordingId'] as String,
            startMs: (e['startMs'] as num).toDouble(),
            offsetMs: (e['offsetMs'] as num).toDouble(),
            trackMs: (e['trackMs'] as num?)?.toDouble(),
          ),
      ];
    } catch (e) {
      // 404 = server relaci nezná (restart API) -- navázat hned novým
      // streamem, ne až po vyčerpání bufferu. Jinak síť -- příště.
      if (e is ApiException && e.statusCode == 404 && _radioSession == sid && _appVisible &&
          now.difference(_radioLastRestart) > const Duration(seconds: 15)) {
        debugPrint('AudioPlayerController: rádio relace zmizela, navazuji');
        _radioLastRestart = now;
        _restartRadio(state.position);
      }
    }
  }

  /// Poslat serveru nové pořadí dalších skladeb (přidání/odebrání/přeřazení
  /// ve frontě, shuffle, opakování).
  void _radioSyncUpcoming() {
    final sid = _radioSession;
    if (!_radioActive || sid == null) return;
    final ids = [for (final i in _upcomingOrder()) state.queue[i].recordingId];
    final api = _ref.read(apiClientProvider);
    // Za předchozí PUT (založení / minulá úprava), ať pořadí na serveru
    // odpovídá pořadí úprav.
    _radioSync = _radioSync.then<void>((_) async {
      if (_radioSession != sid) return;
      try {
        await api.putJson('/radio/$sid/queue', body: {'upcoming': ids});
      } catch (_) {}
    });
  }

  Future<void> _radioSync = Future.value();

  /// Pozice ve streamu -> co hraje a kde ve skladbě.
  void _onRadioPosition(Duration streamPosition, {bool measured = false}) {
    // Načítá se jiná skladba (tiché odemknutí / obstarávání): časová osa
    // starého streamu by `nowPlaying` přepnula zpátky na předchozí skladbu.
    if (_loadingTrack) return;
    final ms = streamPosition.inMilliseconds.toDouble();
    _RadioSegment? seg;
    for (final s in _radioTimeline) {
      if (s.startMs <= ms) {
        seg = s;
      } else {
        break;
      }
    }
    if (seg == null) {
      // Skladba ve streamu ještě nezačala (časová osa nedorazila, nebo server
      // posílá ticho, dokud se skladba stahuje) -- pozice zůstává, odkud se
      // začalo. Dřív se k ní přičítal čas streamu: ticho při stahování se
      // počítalo jako přehraná skladba a navázání streamu (pauza, výpadek)
      // ji pak pustilo od té pozice -- chyběl začátek (živě nahlášeno).
      state = state.copyWith(position: _radioStartPosition ?? Duration.zero);
      return;
    }
    final switching = state.nowPlaying?.recordingId != seg.recordingId;
    if (switching) _radioSwitchTo(seg.recordingId);
    final trackPos = Duration(milliseconds: (ms - seg.startMs + seg.offsetMs).round());
    // Skutečné hlášení kousek za dopočtem -> necukat tečkou zpátky (další
    // dopočet už vychází ze skutečné hodnoty a srovná se sám).
    final back = state.position - trackPos;
    if (measured && !switching && back > Duration.zero && back < const Duration(seconds: 1)) return;
    final trackMs = seg.trackMs;
    state = state.copyWith(
      // Zvuk běží -> nenačítá se (viz `_onPlayerStateChanged`).
      isBuffering: _awaitingProvisioning ? null : false,
      position: trackPos,
      duration: trackMs != null ? Duration(milliseconds: trackMs.round()) : state.duration,
    );
    _trackScrobble(trackPos);
    _maybeLoopAb(trackPos);
  }

  /// Server přešel na další skladbu -- přepnout `nowPlaying` bez nového zdroje.
  void _radioSwitchTo(String recordingId) {
    var idx = -1;
    final n = state.nextIndex;
    if (n != null && state.queue[n].recordingId == recordingId) {
      idx = n;
    } else {
      idx = state.queue.indexWhere((q) => q.recordingId == recordingId, state.queueIndex + 1);
      if (idx < 0) idx = state.queue.indexWhere((q) => q.recordingId == recordingId);
    }
    if (idx < 0) return;
    final info = state.queue[idx];
    state = state.copyWith(nowPlaying: info, queueIndex: idx, accentColor: _accentColorCache[info.recordingId]);
    unawaited(_resolveArtworkAndAccent(info));
    _recordRecentlyPlayed(info);
    _beginScrobble(info.recordingId);
    _realtime.playbackPlay(info.recordingId);
  }

  /// Stránka, ze které se aktuální fronta spustila ("/playlists/<id>",
  /// "/library/liked", ...) -- jde s poslechem na server, "Pokračovat v
  /// poslechu" na Domů pak ukáže i playlist, ne jen album skladby.
  String? _queueContext;

  /// Stránka, odkud se fronta spustila, pokud je to detail (playlist, album,
  /// interpret, kategorie...) -- "Přehrává se · X" v přehrávači na ni odkazuje.
  /// Kořeny záložek (Domů, Hledat, Knihovna, Profil) nevrací.
  String? get queueContext {
    final route = _queueContext;
    if (route == null || route.isEmpty) return null;
    const roots = {'/', '/search', '/library', '/profile', '/home'};
    return roots.contains(route) ? null : route;
  }

  String? _currentRoute() {
    try {
      // Detail (playlist, album...) se otevírá `push` nad záložkou -- pak je
      // v konfiguraci jako `ImperativeRouteMatch` a `uri` celé konfigurace
      // hlásí jen záložku ("/library"); poslechy pak neměly playlist.
      final config = _ref.read(appRouterProvider).routerDelegate.currentConfiguration;
      final last = config.isEmpty ? null : config.last;
      // Bez předpony záložky ("/search/playlists/x" -> "/playlists/x"):
      // klíč rozposlouchanosti a odkaz "Přehráváno z" platí ve všech záložkách.
      if (last is ImperativeRouteMatch) return unbranched(last.matches.uri.path);
      return unbranched(config.uri.path);
    } catch (_) {
      return null;
    }
  }

  Future<void> playTrack(NowPlayingInfo info, {String? sourceLabel}) => playQueue([info], 0, sourceLabel: sourceLabel);

  /// "Zkusit znovu" po chybě přehrávání: tatáž skladba ve STEJNÉ frontě.
  /// Dřív to bylo `playTrack(nowPlaying)` -- fronta se zúžila na jedinou
  /// skladbu a zmizel playlist ("Přehráváno z X") i kontext pro Domů.
  /// Po mikrofonu (ladička, Shazam v appce): iOS po nahrávání nechá zvukovou
  /// relaci v nahrávacím / neaktivním stavu a pozastavená skladba se pak už
  /// nerozjela ("nenačítá se" -- živě po ladičce). Relaci vrátit na hudbu a
  /// další Play načte skladbu znovu od stejného místa (jako po znovuotevření
  /// appky); nic se nespustí samo.
  Future<void> recoverAfterMicrophone() async {
    try {
      await _configureSession();
    } catch (_) {}
    // Web: při načítání hraje tiché odemknutí (`playing` true), skladba ale
    // ještě nehraje -- i tehdy obnovit.
    if (state.nowPlaying == null || (_player.playing && !_loadingTrack)) return;
    _maybePersistSession(state, force: true);
    _restoredIdle = true;
  }

  Future<void> retryCurrent() async {
    if (state.nowPlaying == null || state.queue.isEmpty) return;
    _restoredIdle = false;
    await _playAtIndex(state.queueIndex);
  }

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
    Duration? startPosition,
    bool rememberProgress = true,
    ({String? route})? context,
    bool? shuffle,
    List<int>? shuffleOrder,
    RepeatMode? repeatMode,
  }) async {
    if (items.isEmpty) return;
    final index = startIndex.clamp(0, items.length - 1);
    _restoredIdle = false;
    // Nová fronta (i "Pokračovat" / převzetí) = nový poslech, ne pokračování
    // dřívějšího přehrání téže skladby (viz `_announceStart`).
    _scrobbleId = null;
    _rememberProgress = rememberProgress;
    // "Pokračovat" v albu/playlistu: skladba začne tam, kde uživatel skončil.
    _resumeAt = startPosition;
    _resumeFor = startPosition == null ? null : items[index].recordingId;
    // Převzetí z jiného zařízení nese stránku odesílatele -- ta, na které
    // je příjemce zrovna otevřený, s frontou nesouvisí.
    _queueContext = context != null ? context.route : _currentRoute();
    final shuffleOn = shuffle ?? state.shuffleEnabled;
    // Převzaté pořadí jen když sedí na frontu (jinak nové).
    final order = shuffleOn
        ? (shuffleOrder != null && shuffleOrder.length == items.length && shuffleOrder.contains(index)
            ? shuffleOrder
            : _buildShuffleOrder(items.length, index))
        : null;
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
      // Neznámá barva -> zatím barva předchozí skladby, ne `null`: s `null`
      // pozadí spadlo na výchozí fialovo-růžovou a když se barva nové
      // skladby nespočítala (zamčený telefon), zůstalo tak (živě: černobílý
      // obal v sytě purpurovém přehrávači).
      accentColor: _accentColorCache[items[index].recordingId] ?? state.accentColor,
      queue: items,
      queueIndex: index,
      queueSourceLabel: sourceLabel,
      shuffleEnabled: shuffleOn,
      shuffleOrder: order,
      repeatMode: repeatMode ?? state.repeatMode,
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
    _switchKind = 'tap';
    await _playCurrent();
    if (prefetchWholeQueue) {
      _prefetchQueue(items, except: items[index].recordingId);
    } else {
      _provisionAhead();
    }
  }

  // --- Mluvené slovo -----------------------------------------------------------
  //
  // Soubor audioknihy ve frontě: `sp:<kniha>:<soubor>` (features/spoken).
  // Hraje rovnou z `/spoken/files/<soubor>/stream` -- bez obstarávání,
  // poslechů, ListenBrainz a "Naposledy hrané" (nic z toho do hudby nepatří).

  /// Mluvené slovo: soubor audioknihy (`sp:`) nebo epizoda podcastu (`pc:`).
  static bool isSpokenId(String id) => id.startsWith('sp:') || id.startsWith('pc:');

  static String? podcastEpisodeId(String id) => id.startsWith('pc:') ? id.substring(3) : null;

  static ({String bookId, String fileId})? spokenParts(String id) {
    if (!isSpokenId(id)) return null;
    final parts = id.split(':');
    return parts.length == 3 ? (bookId: parts[1], fileId: parts[2]) : null;
  }

  String _streamUrlFor(String id) {
    final episode = podcastEpisodeId(id);
    if (episode != null) {
      return withDeviceToken('${_ref.read(apiClientProvider).baseUrl}/podcasts/episodes/$episode/stream');
    }
    final spoken = spokenParts(id);
    if (spoken != null) {
      return withDeviceToken('${_ref.read(apiClientProvider).baseUrl}/spoken/files/${spoken.fileId}/stream');
    }
    return _ref.read(provisioningRepositoryProvider).streamUrl(id);
  }

  /// Konec fronty knihy, která se ještě stahuje: načíst části, které mezitím
  /// dorazily, přidat je za aktuální a pokračovat další.
  Future<void> _continueSpokenBook() async {
    final current = state.nowPlaying;
    final parts = current == null ? null : spokenParts(current.recordingId);
    if (parts == null) return;
    try {
      final json = await _ref.read(apiClientProvider).getJson('/spoken/books/${parts.bookId}');
      if (state.nowPlaying?.recordingId != current!.recordingId) return;
      final have = {for (final q in state.queue) q.recordingId};
      final more = [
        for (final f in json['files'] as List<dynamic>? ?? const [])
          if (!have.contains('sp:${parts.bookId}:${(f as Map<String, dynamic>)['id']}'))
            NowPlayingInfo(
              recordingId: 'sp:${parts.bookId}:${f['id']}',
              title: f['title'] as String? ?? current.title,
              artistName: current.artistName,
              artworkUrl: current.artworkUrl,
            ),
      ];
      if (more.isEmpty) return;
      state = state.copyWith(queue: [...state.queue, ...more]);
      await next(auto: true);
    } catch (_) {}
  }

  DateTime _spokenSavedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Kde v knize jsem -- každých 15 s při hraní, hned při pauze / odchodu.
  void _maybeSaveSpokenProgress({bool force = false}) {
    final s = state;
    final id = s.nowPlaying?.recordingId;
    if (id == null || !isSpokenId(id)) return;
    final now = DateTime.now();
    if (!force && now.difference(_spokenSavedAt) < const Duration(seconds: 15)) return;
    _spokenSavedAt = now;
    final duration = s.duration;
    final episode = podcastEpisodeId(id);
    if (episode != null) {
      final done = duration != null && duration > Duration.zero && s.position >= duration - const Duration(seconds: 30);
      unawaited(_ref
          .read(apiClientProvider)
          .putJson('/podcasts/episodes/$episode/progress', body: {
            'positionMs': s.position.inMilliseconds,
            'finished': done,
          })
          .then<void>((_) {}, onError: (Object _) {}));
      return;
    }
    final parts = spokenParts(id);
    if (parts == null) return;
    final finished =
        !s.hasNext && duration != null && duration > Duration.zero && s.position >= duration - const Duration(seconds: 30);
    unawaited(_ref
        .read(apiClientProvider)
        .putJson('/spoken/books/${parts.bookId}/progress', body: {
          'fileId': parts.fileId,
          'positionMs': s.position.inMilliseconds,
          'finished': finished,
        })
        .then<void>((_) {}, onError: (Object _) {}));
  }

  /// Kolik skladeb za právě hrající má být na serveru už stažených. Jedna:
  /// přeskočení hraje hned a další se dožádá, jakmile se na ni přepne
  /// (dvě dopředu stahovaly zbytečně -- Kryštof 7. 10.).
  static const _provisionAheadCount = 1;

  /// Na serveru obstarat další skladby ve frontě hned, jak začne hrát nová
  /// (ne až v 80 % té aktuální): přeskočení na další pak hraje hned místo
  /// čekání na stažení, i když uživatel přeskakuje rychle po sobě. Jen server
  /// (do telefonu se nic nestahuje); už stažené / obstarávané se nežádají
  /// znovu -- `provision()` by je na chvíli přepnul na REQUESTING a rychlá
  /// cesta v `_playCurrent` by je minula.
  void _provisionAhead() {
    final provisioning = _ref.read(provisioningControllerProvider.notifier);
    final known = _ref.read(provisioningControllerProvider);
    for (final id in upcomingRecordingIds(state, _provisionAheadCount)) {
      if (isSpokenId(id)) continue;
      final k = known[id];
      if (k == null || (!k.isAvailable && !k.isInFlight && k.streamUrl == null)) {
        unawaited(provisioning.provision(id));
      }
    }
  }

  /// Nahrávky, které budou hrát po té aktuální (pořadí podle shuffle /
  /// opakování), bez té právě hrající a bez opakování.
  @visibleForTesting
  static List<String> upcomingRecordingIds(AudioPlayerState state, int count) {
    final out = <String>[];
    final current = state.nowPlaying?.recordingId;
    var s = state;
    for (var i = 0; i < count; i++) {
      final next = s.nextIndex;
      if (next == null || next >= s.queue.length) break;
      final id = s.queue[next].recordingId;
      if (id != current && !out.contains(id)) out.add(id);
      s = s.copyWith(queueIndex: next);
    }
    return out;
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

  // --- Opentify Connect ----------------------------------------------------

  /// Co přesně hraje (fronta, index, pozice) -- pro převzetí na jiném zařízení.
  Map<String, dynamic>? handoffSnapshot() {
    final s = state;
    if (s.nowPlaying == null || s.queue.isEmpty) return null;
    return {
      'queue': [for (final q in s.queue) _infoToJson(q)],
      'index': s.queueIndex,
      'positionMs': s.position.inMilliseconds,
      'isPlaying': s.isPlaying,
      if (s.queueSourceLabel != null) 'sourceLabel': s.queueSourceLabel,
      // Vždy (i null) -- příjemce pozná nový formát od starého bez klíče.
      'context': _queueContext,
      'shuffle': s.shuffleEnabled,
      if (s.shuffleOrder != null) 'shuffleOrder': s.shuffleOrder,
      'repeat': s.repeatMode.name,
    };
  }

  /// Převzít přehrávání z jiného zařízení: stejná fronta, stejné místo.
  Future<void> resumeFromHandoff(Map<String, dynamic> snapshot) async {
    final queue = [
      for (final e in (snapshot['queue'] as List<dynamic>? ?? const [])) _infoFromJson(e as Map<String, dynamic>),
    ];
    if (queue.isEmpty) return;
    final index = ((snapshot['index'] as num?)?.toInt() ?? 0).clamp(0, queue.length - 1);
    await playQueue(
      queue,
      index,
      sourceLabel: snapshot['sourceLabel'] as String?,
      startPosition: Duration(milliseconds: (snapshot['positionMs'] as num?)?.toInt() ?? 0),
      // Starší snímky tyhle klíče nemají -- pak jako dřív (místní nastavení).
      context: snapshot.containsKey('context') ? (route: snapshot['context'] as String?) : null,
      shuffle: snapshot['shuffle'] as bool?,
      shuffleOrder: (snapshot['shuffleOrder'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList(),
      repeatMode: RepeatMode.values.where((m) => m.name == snapshot['repeat']).firstOrNull,
    );
  }

  /// Pauza (povel z jiného zařízení / předání přehrávání jinam).
  /// Vrací, jestli hrálo / mělo po načtení hrát -- Wrapped podle toho po
  /// zavření přehrávání vrátí (`isPlaying` je při načítání false).
  Future<bool> pauseIfPlaying() async {
    if (state.nowPlaying == null) return false;
    if (_loadingTrack) {
      final wanted = !_startPausedWhenReady;
      _deferWhileLoading(play: false);
      return wanted;
    }
    if (!state.isPlaying) return false;
    await togglePlayPause();
    return true;
  }

  Future<void> resumeIfPaused() async {
    if (state.nowPlaying == null) return;
    if (_deferWhileLoading(play: true)) return;
    if (!state.isPlaying) await togglePlayPause();
  }

  // --- Kapitoly knihy v jednom souboru (m4b) ---------------------------------
  //
  // Další / Předchozí (i z uzamčené obrazovky) skáčou po kapitolách, dokud
  // je kam; pak na další / předchozí soubor jako jindy.

  List<int> _chapterStarts = const [];
  List<String> _chapterTitles = const [];
  String? _chaptersFor;

  /// Název kapitoly na pozici `at` v právě hrajícím souboru (m4b), jinak null.
  String? chapterTitleAt(String recordingId, Duration at) {
    if (_chaptersFor != recordingId) return null;
    final ms = at.inMilliseconds;
    String? title;
    for (var i = 0; i < _chapterStarts.length; i++) {
      if (_chapterStarts[i] <= ms) title = _chapterTitles[i];
    }
    return (title == null || title.isEmpty) ? null : title;
  }

  Future<void> _loadChapters(String recordingId) async {
    final parts = spokenParts(recordingId);
    _chapterStarts = const [];
    _chaptersFor = null;
    if (parts == null) return;
    try {
      final json = await _ref.read(apiClientProvider).getJson('/spoken/books/${parts.bookId}');
      final file = (json['files'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .where((f) => f['id'] == parts.fileId)
          .firstOrNull;
      final chapters = [
        for (final c in file?['chapters'] as List<dynamic>? ?? const [])
          (start: ((c as Map)['startMs'] as num).toInt(), title: c['title'] as String? ?? ''),
      ]..sort((a, b) => a.start.compareTo(b.start));
      if (state.nowPlaying?.recordingId == recordingId && chapters.length > 1) {
        _chapterStarts = [for (final c in chapters) c.start];
        _chapterTitles = [for (final c in chapters) c.title];
        _chaptersFor = recordingId;
      }
    } catch (_) {}
  }

  /// `true` = přeskočeno v rámci souboru (nic dalšího nedělat).
  bool _skipChapter({required bool forward}) {
    if (_chaptersFor == null || _chaptersFor != state.nowPlaying?.recordingId) return false;
    final pos = state.position.inMilliseconds;
    if (forward) {
      final next = _chapterStarts.where((s) => s > pos + 1000).firstOrNull;
      if (next == null) return false;
      unawaited(seek(Duration(milliseconds: next)));
      return true;
    }
    final current = _chapterStarts.lastWhere((s) => s <= pos, orElse: () => 0);
    // Jako u skladeb: po 3 s na začátek kapitoly, jinak předchozí.
    if (pos - current > 3000) {
      unawaited(seek(Duration(milliseconds: current)));
      return true;
    }
    final earlier = _chapterStarts.where((s) => s < current).lastOrNull;
    if (earlier == null) return false;
    unawaited(seek(Duration(milliseconds: earlier)));
    return true;
  }

  /// `auto`: skladba dohrála (ne klepnutí) -- jen pro měření rychlosti startu.
  Future<void> next({bool auto = false}) async {
    if (!auto && _skipChapter(forward: true)) return;
    final index = state.nextIndex;
    if (index == null) return;
    _switchKind = auto ? 'auto' : 'manual';
    await _playAtIndex(index);
  }

  // --- Měření rychlosti startu skladby ---------------------------------------
  //
  // Od přepnutí (dohrání, Další, klepnutí) do prvního posunu pozice při
  // přehrávání. Po 8 měřeních jedno hlášení do logu API (`client-log`,
  // kind `playback-start`): druh, jestli byla skladba už stažená na serveru
  // (r) / čekalo se na stažení (w) / z telefonu (l), milisekundy.
  String _switchKind = 'tap';
  DateTime? _switchAt;
  String _switchTag = '';
  final List<String> _startSamples = [];

  /// Generace zdroje v okamžiku přepnutí: počítá se až pozice NOVĚ
  /// načteného zdroje. Dřív stačila pozice ještě hrající předchozí skladby
  /// a u stažených skladeb vycházely nesmyslné 2-4 ms (web test 6. 10.).
  int _switchGen = -1;

  void _markSwitch(String tag) {
    _switchAt = DateTime.now();
    _switchGen = _sourceGen;
    _switchTag = '$_switchKind $tag${_radioMode ? ' radio' : ''}';
    _switchKind = 'manual';
  }

  void _maybeRecordStart(Duration position) {
    final at = _switchAt;
    if (at == null || _priming || !_player.playing || position <= Duration.zero) return;
    if (_readyGen <= _switchGen || _readyGen != _sourceGen) return;
    _switchAt = null;
    final ms = DateTime.now().difference(at).inMilliseconds;
    if (ms > 120000) return; // mezitím pauza / pryč od appky
    _startSamples.add('$_switchTag $ms');
    if (_startSamples.length >= 8) {
      diagReport('playback-start', _startSamples.join('; '));
      _startSamples.clear();
    }
  }

  /// Standardní UX napříč přehrávači (Spotify, Finamp...): první ~3s skladby
  /// "Předchozí" skočí na předchozí skladbu, později jen restartuje tu
  /// aktuální -- jinak by neúmyslné dvojité kliknutí za sebou přeskočilo o
  /// dvě skladby zpátky místo restartu poslouchané.
  Future<void> previous() async {
    if (_skipChapter(forward: false)) return;
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
    _radioSyncUpcoming();
  }

  /// Přesune celý sbalený blok (album/playlist přidaný najednou) --
  /// `newIndex` jako u `reorderQueue` (poloha po vyjmutí JEDNÉ položky).
  /// Jen v části "Další ve frontě" (za právě hrající skladbou).
  void reorderRange(int start, int count, int newIndex) {
    final q = state.queue;
    if (count <= 1) return reorderQueue(start, newIndex);
    if (start <= state.queueIndex || start + count > q.length) return;
    // Cíl uvnitř samotného bloku = žádný pohyb.
    if (newIndex >= start && newIndex < start + count) return;
    final block = q.sublist(start, start + count);
    final rest = [...q]..removeRange(start, start + count);
    final insertAt = (newIndex > start ? newIndex - count + 1 : newIndex).clamp(state.queueIndex + 1, rest.length);
    rest.insertAll(insertAt, block);
    state = state.copyWith(queue: rest, shuffleEnabled: false);
    _radioSyncUpcoming();
  }

  /// Odebere skladbu z fronty (swipe ve frontě). Právě hrající se odebrat
  /// nedá -- na to je "Další". Zamíchané pořadí se přepočítá (indexy za
  /// odebranou se posunou o jednu).
  void removeFromQueue(int index) {
    if (index < 0 || index >= state.queue.length || index == state.queueIndex) return;
    final newQueue = [...state.queue]..removeAt(index);
    final newCurrentIndex = index < state.queueIndex ? state.queueIndex - 1 : state.queueIndex;
    var newShuffleOrder = state.shuffleOrder;
    if (newShuffleOrder != null) {
      newShuffleOrder = [
        for (final i in newShuffleOrder)
          if (i != index) i > index ? i - 1 : i,
      ];
    }
    state = state.copyWith(queue: newQueue, queueIndex: newCurrentIndex, shuffleOrder: newShuffleOrder);
    _radioSyncUpcoming();
  }

  /// Zlomené srdce: skladba zmizí ze zbytku fronty (právě hrající se
  /// nepřeruší -- na to je "Další").
  void dropUpcoming(String recordingId) {
    for (var i = state.queue.length - 1; i >= 0; i--) {
      if (i != state.queueIndex && state.queue[i].recordingId == recordingId) removeFromQueue(i);
    }
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
    _radioSyncUpcoming();
    unawaited(_ref.read(provisioningControllerProvider.notifier).provision(info.recordingId));
  }

  /// Označí skladby jako jeden blok fronty (viz `NowPlayingInfo.groupId`).
  /// Jedna skladba blok netvoří.
  List<NowPlayingInfo> _asGroup(List<NowPlayingInfo> infos, String? label) {
    if (infos.length < 2) return infos;
    final id = 'g${DateTime.now().microsecondsSinceEpoch}';
    return [for (final i in infos) i.withGroup(id, label)];
  }

  /// Odebere celý blok z fronty najednou (kromě právě hrající skladby).
  void removeGroup(String groupId) {
    final queue = state.queue;
    final removed = <int>{
      for (var i = 0; i < queue.length; i++)
        if (queue[i].groupId == groupId && i != state.queueIndex) i,
    };
    if (removed.isEmpty) return;
    int shift(int i) => i - removed.where((r) => r < i).length;
    final newQueue = [
      for (var i = 0; i < queue.length; i++)
        if (!removed.contains(i)) queue[i],
    ];
    var newShuffleOrder = state.shuffleOrder;
    if (newShuffleOrder != null) {
      newShuffleOrder = [
        for (final i in newShuffleOrder)
          if (!removed.contains(i)) shift(i),
      ];
    }
    state = state.copyWith(queue: newQueue, queueIndex: shift(state.queueIndex), shuffleOrder: newShuffleOrder);
    _radioSyncUpcoming();
  }

  /// Celé album/playlist hned za aktuální skladbu (dlouhý stisk na kartě ->
  /// "Přehrát jako další") -- nepřeruší, co hraje. Když nic nehraje, spustí.
  Future<void> playNextAll(List<NowPlayingInfo> infos, {String? sourceLabel}) async {
    if (infos.isEmpty) return;
    infos = _asGroup(infos, sourceLabel);
    if (state.nowPlaying == null) {
      await playQueue(infos, 0, sourceLabel: sourceLabel);
      return;
    }
    final insertAt = state.queueIndex + 1;
    final n = infos.length;
    final newQueue = [...state.queue]..insertAll(insertAt, infos);
    var newShuffleOrder = state.shuffleOrder;
    if (state.shuffleEnabled && newShuffleOrder != null) {
      // Stejně jako `playNext`: posunout indexy a vložit nové hned za
      // aktuální -- v pořadí, v jakém jsou na albu/v playlistu.
      final shifted = newShuffleOrder.map((i) => i >= insertAt ? i + n : i).toList();
      shifted.insertAll(shifted.indexOf(state.queueIndex) + 1, [for (var k = 0; k < n; k++) insertAt + k]);
      newShuffleOrder = shifted;
    }
    state = state.copyWith(queue: newQueue, shuffleOrder: newShuffleOrder);
    _radioSyncUpcoming();
    // Jen první -- stáhnout celé album dopředu by zahltilo frontu stahování.
    unawaited(_ref.read(provisioningControllerProvider.notifier).provision(infos.first.recordingId));
  }

  /// Celé album/playlist na konec fronty. Když nic nehraje, spustí.
  Future<void> addAllToQueue(List<NowPlayingInfo> infos, {String? sourceLabel}) async {
    if (infos.isEmpty) return;
    infos = _asGroup(infos, sourceLabel);
    if (state.nowPlaying == null) {
      await playQueue(infos, 0, sourceLabel: sourceLabel);
      return;
    }
    final start = state.queue.length;
    final newQueue = [...state.queue, ...infos];
    var newShuffleOrder = state.shuffleOrder;
    if (state.shuffleEnabled && newShuffleOrder != null) {
      newShuffleOrder = [...newShuffleOrder, for (var k = 0; k < infos.length; k++) start + k];
    }
    state = state.copyWith(queue: newQueue, shuffleOrder: newShuffleOrder);
    _radioSyncUpcoming();
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
    _radioSyncUpcoming();
    unawaited(_ref.read(provisioningControllerProvider.notifier).provision(info.recordingId));
  }

  void toggleShuffle() {
    final enabling = !state.shuffleEnabled;
    state = state.copyWith(
      shuffleEnabled: enabling,
      shuffleOrder: enabling ? _buildShuffleOrder(state.queue.length, state.queueIndex) : state.shuffleOrder,
    );
    _radioSyncUpcoming();
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
      RepeatMode.one => RepeatMode.endless,
      RepeatMode.endless => RepeatMode.off,
    };
    setRepeatMode(next);
  }

  void setRepeatMode(RepeatMode mode) {
    if (mode == state.repeatMode) return;
    state = state.copyWith(repeatMode: mode);
    _radioSyncUpcoming();
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
  double get _effectiveVolume => (state.volume * (state.normalizationEnabled ? _trackGainFactor : 1.0)).clamp(0.0, 1.0);

  static double _factorForGainDb(double? gainDb) {
    if (gainDb == null) return 1.0;
    return pow(10, gainDb / 20).toDouble().clamp(0.0, 1.0);
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final radio = prefs.getBool(_radioPrefKey);
      if (radio != null) _radioMode = radio;
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
    // Další kapitola / epizoda: jen předem do telefonu (nic se neobstarává).
    if (isSpokenId(next.recordingId)) {
      unawaited(_prefetchFile(next.recordingId));
      return;
    }

    final provisioning = _ref.read(provisioningControllerProvider.notifier);
    final nextState = _ref.read(provisioningControllerProvider)[next.recordingId];
    if (nextState == null || (!nextState.isAvailable && !nextState.isInFlight && nextState.streamUrl == null)) {
      unawaited(provisioning.provision(next.recordingId));
    }
    unawaited(provisioning.fetchLoudnessGain(next.recordingId));
    // Jen naplní `_artworkCache`/`_accentColorCache` -- stav mění, jen když
    // `nowPlaying` odpovídá, což tu ještě neplatí.
    unawaited(_resolveArtworkAndAccent(next));
    unawaited(_prefetchFile(next.recordingId));
  }

  /// Nativní appka: další skladba stažená do telefonu (`PrefetchCache`) --
  /// id -> URL souboru. `_playCurrent` ji pak pustí bez sítě.
  final Map<String, String> _prefetched = {};
  final Set<String> _prefetching = {};

  /// Kapitolu nad tuhle velikost předem do telefonu nestahovat.
  static const _maxSpokenPrefetchBytes = 200 * 1024 * 1024;

  /// Velikost souboru na serveru (1 bajt s Range -> Content-Range), bez stažení.
  Future<int?> _remoteSize(String path) async {
    try {
      final url = withDeviceToken('${_ref.read(apiClientProvider).baseUrl}$path');
      final resp = await http
          .get(Uri.parse(url), headers: {'Range': 'bytes=0-0', ...authHeaders()})
          .timeout(const Duration(seconds: 20));
      final range = resp.headers['content-range'];
      return range == null ? null : int.tryParse(range.split('/').last);
    } catch (_) {
      return null;
    }
  }

  Future<void> _prefetchFile(String id) async {
    if (!PrefetchCache.supported || _radioMode || _prefetched.containsKey(id) || !_prefetching.add(id)) return;
    try {
      if (_ref.read(offlineControllerProvider.notifier).has(id)) return;
      final earlier = await PrefetchCache.existing(id);
      if (earlier != null) {
        _prefetched[id] = earlier;
        return;
      }
      final String path;
      if (isSpokenId(id)) {
        // Kapitola knihy / epizoda: na serveru je celá; obří soubor (celá
        // kniha v jednom m4b) dopředu ne -- paměť i data.
        final episode = podcastEpisodeId(id);
        path = episode != null ? '/podcasts/episodes/$episode/stream' : '/spoken/files/${spokenParts(id)!.fileId}/stream';
        final size = await _remoteSize(path);
        if (size == null || size > _maxSpokenPrefetchBytes) return;
      } else {
        // Soubor musí být na serveru celý (ne ještě se stahující).
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (true) {
          final s = _ref.read(provisioningControllerProvider)[id];
          if (s != null && s.isAvailable && s.streamUrl != null) break;
          if (s == null || s.isFailed || DateTime.now().isAfter(deadline)) return;
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        path = '/tracks/$id/stream';
      }
      final bytes = await _ref.read(apiClientProvider).getBytes(path, timeout: const Duration(minutes: 5));
      final url = await PrefetchCache.put(id, bytes);
      if (url != null) _prefetched[id] = url;
    } catch (e) {
      debugPrint('AudioPlayerController: předem stáhnout $id nešlo ($e)');
    } finally {
      _prefetching.remove(id);
    }
  }

  /// Zamčený iPhone: když skladba dohraje, audio prvek "skončí", iOS uspí
  /// zvukovou relaci a `play()` další skladby, co přijde o pár asynchronních
  /// kroků později, Safari potichu odmítne -- appka ukazovala, že hraje, a
  /// po odemčení skladba začala od začátku (živě nahlášeno). Proto na webu,
  /// když je další skladba už stažená, přepnout ~0,6 s PŘED koncem, dokud
  /// audio ještě hraje (konec skladby bývá ticho). Jinak zůstává běžné
  /// přepnutí po `completed`.
  /// A-B opakování: po dosažení bodu B skok zpět na A (jen pro skladbu, na
  /// které se body nastavily; jinou skladbou se samo zruší).
  bool _maybeLoopAb(Duration position) {
    final ab = _ref.read(abRepeatProvider);
    if (ab == null) return false;
    final current = state.nowPlaying?.recordingId;
    if (ab.recordingId != current) {
      _ref.read(abRepeatProvider.notifier).state = null;
      return false;
    }
    final b = ab.b;
    // V rádiu smyčku vyrábí server (seek = nový stream při každém opakování
    // skákal i ve zvuku -- živě nahlášeno).
    if (_radioActive || b == null || position < b) return false;
    unawaited(seek(ab.a));
    return true;
  }

  /// Zapnutí/vypnutí A-B v rádiu -> nový stream (se smyčkou / bez ní).
  void _onAbChanged(AbRepeat? previous, AbRepeat? next) {
    if (!_radioActive || state.nowPlaying == null) return;
    final id = state.nowPlaying!.recordingId;
    if (next != null && next.b != null && next.recordingId == id && previous?.b != next.b) {
      _restartRadio(next.a);
    } else if (next == null && previous?.b != null && previous?.recordingId == id) {
      _restartRadio(state.position);
    }
  }

  static const _earlyAdvanceWindow = Duration(milliseconds: 600);
  String? _earlyAdvancedFrom;
  DateTime? _earlyAdvancedAt;

  void _maybeAdvanceEarly(Duration position) {
    if (!kIsWeb || _priming || !_player.playing) return;
    final current = state.nowPlaying;
    final duration = state.duration;
    if (current == null || duration == null || duration < const Duration(seconds: 10)) return;
    if (_earlyAdvancedFrom == current.recordingId) return;
    if (duration - position > _earlyAdvanceWindow) return;
    if (state.repeatMode == RepeatMode.one) return;
    final nextIndex = state.nextIndex;
    if (nextIndex == null || nextIndex >= state.queue.length) return;
    final next = _ref.read(provisioningControllerProvider)[state.queue[nextIndex].recordingId];
    if (next == null || next.status != 'AVAILABLE' || next.streamUrl == null) return;
    _earlyAdvancedFrom = current.recordingId;
    _earlyAdvancedAt = DateTime.now();
    unawaited(this.next(auto: true));
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
        // Skladba se zrovna načítá: jen záměr (pauza by na webu rozbila
        // tiché odemknutí), po načtení zůstane pozastavená.
        if (_loadingTrack) {
          _startPausedWhenReady = true;
        } else {
          await _player.pause();
        }
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
    _restoredIdle = false;
    _primeAudioElement(info.recordingId);
    state = AudioPlayerState(
      nowPlaying: info,
      isPlaying: false,
      isBuffering: true,
      position: Duration.zero,
      duration: null,
      // Stejný důvod jako `playQueue` výš -- cache místo natvrdo `null`.
      accentColor: _accentColorCache[info.recordingId] ?? state.accentColor,
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
    // Až po `provision` právě hrající (pořadí ve frontě serveru, viz `playQueue`).
    if (state.nowPlaying?.recordingId == info.recordingId) _provisionAhead();
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
    // Pozice k navázání patří jiné skladbě (chyba A, pak přeskočeno) --
    // jinak by A příště začala uprostřed.
    if (_resumeFor != info.recordingId) {
      _resumeAt = null;
      _resumeFor = null;
    }
    unawaited(_resolveArtworkAndAccent(info));
    _provisioningSub?.close();
    _provisioningSub = null;
    _awaitingProvisioning = false;
    _startPausedWhenReady = false; // nově zvolená skladba má hrát
    _sourceGen++; // přerušený `setUrl` předchozího zdroje už nic nehlásí

    final provisioning = _ref.read(provisioningControllerProvider.notifier);

    // Offline: skladba je uložená v zařízení -> hrát odtud (i bez internetu).
    // Mimo rádio (to je stream ze serveru) -- viz `isLocal`.
    final offline = _ref.read(offlineControllerProvider.notifier);
    final knownAtStart = _ref.read(provisioningControllerProvider)[info.recordingId];
    final prefetched = _radioMode ? null : _prefetched[info.recordingId];
    _markSwitch(offline.has(info.recordingId)
        ? 'l'
        : prefetched != null
            ? 'p'
            : (knownAtStart?.status == 'AVAILABLE' && knownAtStart?.streamUrl != null ? 'r' : 'w'));
    // Mluvené slovo: nic se neobstarává (kniha je na serveru celá, podcast
    // server přeposílá). Epizoda stažená do telefonu hraje odtud.
    if (isSpokenId(info.recordingId)) {
      // Další kapitola předem v telefonu (jako u hudby) -- hned a bez sítě.
      final ready = _radioMode ? null : _prefetched[info.recordingId];
      if (ready != null) {
        unawaited(_startStream(info, ready, isProgressive: false, isLocal: true));
        return;
      }
      if (podcastEpisodeId(info.recordingId) != null && offline.has(info.recordingId)) {
        final local = await offline.localUrl(info.recordingId);
        if (state.nowPlaying?.recordingId != info.recordingId) return;
        if (local != null) {
          unawaited(_startStream(info, local, isProgressive: false, isLocal: true));
          return;
        }
      }
      unawaited(_startStream(info, _streamUrlFor(info.recordingId), isProgressive: false));
      return;
    }
    // Předem stažená kopie v telefonu: hned a synchronně (zamčený telefon,
    // viz rychlá cesta níž). Chyba souboru -> `_handleStreamFailure` jde na server.
    if (prefetched != null && !offline.has(info.recordingId)) {
      unawaited(_startStream(info, prefetched, isProgressive: false, isLocal: true));
      return;
    }
    if (offline.has(info.recordingId)) {
      final local = await offline.localUrl(info.recordingId);
      if (state.nowPlaying?.recordingId != info.recordingId) return;
      if (local != null) {
        unawaited(_startStream(info, local, isProgressive: false, isLocal: true));
        return;
      }
    }

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
        _streamUrlFor(info.recordingId),
        isProgressive: false,
      ));
      return;
    }

    // Skladba se teprve obstarává: předchozí zvuk (i iOS rádio stream fronty)
    // ztlumit hned -- dřív dál hrála stará skladba, zatímco UI ukazovalo
    // novou "Ve frontě..." (živě: SoundCloud remix, který se nikdy nestáhl).
    _awaitingProvisioning = true; // zastavení níž nesmí schovat načítání
    // Rádio starého streamu ukončit -- jeho časová osa by jinak během čekání
    // přepnula `nowPlaying` zpátky na předchozí skladbu a kolečko by se
    // točilo navždy (iPhone, nestažená skladba).
    _stopRadio();
    // Zastavit, ne jen pauznout: s pauzou zůstal starý zdroj načtený a Play
    // (sluchátka, zamčená obrazovka) ho rozehrálo pod názvem nové skladby.
    // Web ne: tam už starou skladbu nahradilo tiché "odemknutí" přehrávače
    // (`_primeAudioElement`) a jeho pauza rozbila následné spuštění streamu
    // (přehrávač pak visel v "Načítám…").
    if (!kIsWeb && (_player.playing || _player.processingState != ProcessingState.idle)) {
      unawaited(_player.stop());
    }
    provisioning.awaitedRecordingId = info.recordingId;

    // `interactive` -- tuhle skladbu uživatel chce slyšet TEĎ (prioritní
    // fronta + závod slskd/YouTube na backendu), na rozdíl od prefetche.
    await provisioning.provision(info.recordingId, interactive: true);
    if (state.nowPlaying?.recordingId != info.recordingId) return; // mezitím přeskočeno jinam

    var result = _ref.read(provisioningControllerProvider)[info.recordingId];
    if (result != null && result.isFailed) result = TrackProvisioningState(status: 'FAILED', error: result.error);
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
        _streamUrlFor(info.recordingId),
        isProgressive: !result.isAvailable,
      );
    } else if (result != null && result.isFailed) {
      _awaitingProvisioning = false;
      _priming = false;
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
    _provisioningSub?.close();
    // `initial`: vyhodnocení stavu, který už platí -- posluchač reaguje jen
    // na ZMĚNY a u skladby, co už je AVAILABLE (chyba streamu uprostřed
    // hraní), by žádná nepřišla a přehrávač visel v "Načítám…" navždy.
    void check(Map<String, TrackProvisioningState> next, {bool initial = false}) {
      if (state.nowPlaying?.recordingId != info.recordingId) {
        _provisioningSub?.close();
        _provisioningSub = null;
        _awaitingProvisioning = false;
        return;
      }
      final result = next[info.recordingId];
      // Hned po přihlášení jen hotový výsledek; rozpracovaný progresivní
      // stream by po chybě naskočil hned znovu a mohl se točit dokola.
      if (initial && !(result != null && (result.isFailed || (result.isAvailable && result.streamUrl != null)))) {
        return;
      }
      if (result == null) {
        // Stav zmizel (watchdog ho zahodil) -- zeptat se znovu, jinak by
        // přehrávač čekal navždy.
        unawaited(_ref.read(provisioningControllerProvider.notifier).provision(info.recordingId, interactive: true));
        return;
      }
      if (result.isFailed) {
        // Chyba napřed: FAILED se zbylým starým `streamUrl` jinak spustil
        // mrtvý progresivní stream dokola a chyba se nikdy neukázala.
        _provisioningSub?.close();
        _provisioningSub = null;
        _awaitingProvisioning = false;
        _priming = false;
        state = state.copyWith(isBuffering: false, error: result.error ?? 'obstarání skladby selhalo');
        return;
      }
      if (result.streamUrl != null) {
        _provisioningSub?.close();
        _provisioningSub = null;
        // Stejný důvod jako v `_playCurrent` -- vlastní absolutní URL, ne
        // backendova relativní `result.streamUrl`.
        unawaited(_startStream(
          info,
          _streamUrlFor(info.recordingId),
          isProgressive: !result.isAvailable,
        ));
      }
    }

    _provisioningSub = _ref.listen<Map<String, TrackProvisioningState>>(
      provisioningControllerProvider,
      (previous, next) => check(next),
    );
    check(_ref.read(provisioningControllerProvider), initial: true);
  }

  /// `isProgressive`: `true` když `streamUrl` přišel z `track.streaming`
  /// (soubor se ještě stahuje přes slskd, viz `OnFileLocated`/
  /// `_tail_growing_file` v backendu), ne z finálního `track.available`.
  /// Rozlišení je klíčové pro `_handleStreamFailure` níž -- selhání na ještě
  /// nedokončeném souboru neznamená, že skladba nejde přehrát vůbec.
  /// Hraje se zrovna ještě rostoucí soubor (viz `_startStream`)?
  bool _currentProgressive = false;

  Future<void> _startStream(
    NowPlayingInfo info,
    String streamUrl, {
    required bool isProgressive,
    bool isLocal = false,
  }) async {
    _currentProgressive = isProgressive;
    _currentLocal = isLocal;
    // Zdroj se načítá -> Pauza má pauzovat, ne znovu načítat (po mikrofonu).
    _restoredIdle = false;
    _priming = false;
    _awaitingProvisioning = false;
    _warmedUpAfter = null;
    // Chyby/dokončení staršího `setUrl` (přerušené tímhle) se k tomuhle
    // zdroji nevztahují -- viz `_sourceGen`.
    final gen = ++_sourceGen;
    final startPaused = _startPausedWhenReady;
    _startPausedWhenReady = false;
    _unannounced = info;
    _unannouncedResume = null;
    _scrobbleOnPlay = null;
    // iOS: místo souboru skladby jeden nepřetržitý stream celé fronty (viz
    // `_startRadio`). Ještě se stahující soubor (progresivní přehrávání) jde
    // postaru -- rádio řadí jen hotové skladby.
    if (_radioMode && !isProgressive && !isLocal && !isSpokenId(info.recordingId)) {
      _radioStartGrace = _radioStartGraceMin;
      final radioResume = _takeResume(info);
      _unannouncedResume = radioResume;
      streamUrl = _startRadio(info, radioResume ?? Duration.zero);
    } else {
      _stopRadio();
    }
    // Korekci z cache (už stažené skladby ji dostaly rovnou v `provision()`)
    // nastavíme PŘED spuštěním, ať první vteřina nehraje nahlas a pak se
    // neztlumí. Neznámá korekce -> 1.0, `_loadGainFor` ji případně doplní.
    // V rádiu ji aplikuje rovnou server.
    if (isProgressive) _watchProgressive(info);
    _trackGainFactor = _radioActive
        ? 1.0
        : _factorForGainDb(_ref.read(provisioningControllerProvider.notifier).loudnessGainFor(info.recordingId));
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
      final resumeAt = _radioActive ? null : _takeResume(info);
      if (resumeAt != null) {
        _unannouncedResume = resumeAt;
        // Selhání hned při načtení pak naváže odsud, ne od staré pozice / 0:00.
        state = state.copyWith(position: resumeAt);
      }
      // Pauza během načítání: zdroj jen připravit. `playing` po tichém
      // odemknutí zůstává true a `setUrl` by se rozehrál sám -- proto pauza
      // napřed (tady už nevadí: Play pak přijde z klepnutí).
      if (startPaused && _player.playing) await _player.pause();
      if (gen != _sourceGen) return;
      // Pojistka: hotový soubor, který se ani za 15 s nenačte (zaseknuté
      // spojení, iOS přehrávač čeká donekonečna), je chyba -- dřív se
      // kolečko točilo navždy. Rostoucí soubor může čekat na data déle.
      if (!isProgressive) {
        Timer(_loadTimeout, () {
          if (gen != _sourceGen || _readyGen == gen || state.nowPlaying?.recordingId != info.recordingId) return;
          _handleStreamFailure(info, TimeoutException('zdroj se nenačetl', _loadTimeout), isProgressive: false);
        });
      }
      final durationFuture = _player.setUrl(streamUrl, initialPosition: resumeAt);
      if (!startPaused) {
        unawaited(_player.play().catchError((Object e) {
          if (gen != _sourceGen) return;
          debugPrint('AudioPlayerController: play() selhalo pro ${info.recordingId}: $e');
          _handleStreamFailure(info, e, isProgressive: isProgressive);
        }));
      }
      await durationFuture;
      if (gen != _sourceGen) return; // mezitím spuštěn jiný zdroj
      _readyGen = gen;
      _reprovisioned = null;
      // `setUrl` znovu načte celý zdroj -- pro jistotu znovu vynutíme
      // rychlost/hlasitost z předchozí skladby, ať se novým zdrojem
      // nevrátí na výchozí hodnoty.
      await _player.setSpeed(state.speed);
      _applyVolume();
      if (_radioActive) _installMediaHandlers();
      // Play mezitím (klepnutí během `setUrl`) -> skutečný stav, ne natvrdo
      // "pozastaveno".
      if (startPaused) state = state.copyWith(isPlaying: _player.playing, isBuffering: false);
      _announceStart(info, paused: startPaused && !_player.playing, resumedAt: _unannouncedResume);
      if (!_radioActive &&
          _ref.read(provisioningControllerProvider.notifier).loudnessGainFor(info.recordingId) == null) {
        unawaited(_loadGainFor(info.recordingId));
      }
    } catch (e) {
      // Přerušené novějším `_startStream` (návaznost, přeskočení) -- žádná chyba.
      if (gen != _sourceGen) return;
      debugPrint('AudioPlayerController: setUrl() selhalo pro ${info.recordingId}: $e');
      // Záměr "pozastaveno" platí i pro další pokus -- jinak se skladba po
      // navázání sama rozehrála (po předání obě zařízení, do nahrávání Shazamu).
      _startPausedWhenReady = startPaused;
      _handleStreamFailure(info, e, isProgressive: isProgressive);
    }
  }

  /// Zdroj z `_startStream`, jehož start se ještě neoznámil (historie,
  /// poslech, Connect) -- když `setUrl` přeruší restart rádia (posun hned po
  /// spuštění), oznámí ho `_restartRadio`.
  NowPlayingInfo? _unannounced;

  /// Pozice, od které `_unannounced` navazuje (null = start od začátku).
  Duration? _unannouncedResume;

  /// Pozastaveně načtená skladba: poslech a "právě hraje" až s prvním
  /// skutečným přehráváním (`_onPlayerStateChanged`), ne při načtení.
  String? _scrobbleOnPlay;

  void _announceStart(NowPlayingInfo info, {required bool paused, Duration? resumedAt}) {
    _unannounced = null;
    _unannouncedResume = null;
    if (isSpokenId(info.recordingId)) {
      // Kniha: jen "právě hraje" pro Connect, žádný poslech ani historie.
      // Předchozí hudební skladbu ale dopočítat (jinak by se ztratil poslech).
      _finishScrobble();
      _scrobbleId = null;
      unawaited(_loadChapters(info.recordingId));
      if (!paused) _realtime.playbackPlay(info.recordingId, positionMs: resumedAt?.inMilliseconds ?? 0);
      return;
    }
    if (testMode) {
      // Test přehrávání (Profil): žádný poslech, historie ani "právě hraje".
      _finishScrobble();
      _scrobbleId = null;
      return;
    }
    if (resumedAt != null && _scrobbleId == info.recordingId) {
      // Navázání téhož přehrávání (po chybě, mikrofonu): poslech běží dál --
      // nový by u dlouhých skladeb nahlásil poslech podruhé a ztratil "slyšeno".
      _scrobbleLastPos = null;
      if (!paused) _realtime.playbackPlay(info.recordingId, positionMs: resumedAt.inMilliseconds);
    } else if (paused) {
      _scrobbleOnPlay = info.recordingId;
    } else {
      _realtime.playbackPlay(info.recordingId);
      _beginScrobble(info.recordingId);
    }
    _recordRecentlyPlayed(info);
  }

  static const _loadTimeout = Duration(seconds: 15);

  /// Běží test přehrávání (`features/profile/playback_test_screen.dart`):
  /// skladby se nezapočítají do poslechů / historie / ListenBrainz.
  bool testMode = false;

  /// Skladba, kterou už `_handleStreamFailure` po chybě jednou znovu
  /// obstarával (do dalšího úspěšného načtení) -- podruhé už chyba.
  String? _reprovisioned;

  /// Generace zdroje, který je automatickým druhým pokusem po chybě sítě
  /// (`_handleStreamFailure`) -- jeho selhání už se ukáže jako chyba.
  int _autoRetryGen = -1;

  /// Pozice, od které druhý pokus skutečně hraje (viz `_maybeReleaseAutoRetry`).
  Duration? _autoRetryFrom;

  /// Druhý pokus už pár vteřin hraje -> další výpadek smí zase jednou navázat
  /// sám (dřív jen jednou za celou dobu zdroje).
  void _maybeReleaseAutoRetry(Duration position) {
    if (_autoRetryGen != _sourceGen || _readyGen != _sourceGen || !_player.playing) return;
    final from = _autoRetryFrom ??= position;
    if (position - from < const Duration(seconds: 5)) return;
    _autoRetryGen = -1;
    _autoRetryFrom = null;
  }

  /// Generace zdroje: zvyšuje ji každý `_startStream`; `_readyGen` je ta,
  /// jejíž `setUrl` doběhl. Chyba z `playbackEventStream` se počítá jen pro
  /// načtený aktuální zdroj -- dřív chyba předchozího zdroje doputovala až po
  /// přepnutí a nová skladba ukázala "Nepodařilo se přehrát" / restart.
  /// (Chyby během načítání řeší `catch` v `_startStream`.)
  int _sourceGen = 0;
  int _readyGen = -1;

  /// Hraje se offline soubor ze zařízení (mimo obstarávání serveru).
  bool _currentLocal = false;

  /// Přehrávání z ještě se stahujícího souboru: když stažení spadne a server
  /// ho zkusí znovu, starý stream je mrtvý a přehrávač jen visel v načítání
  /// -- druhý, úspěšný pokus už nikdo neposlouchal (živě: Tavern Brawl,
  /// La Havana). Po retry čekat na nový výsledek; po hotovém souboru navázat
  /// od stejného místa, pokud zrovna nehraje.
  void _watchProgressive(NowPlayingInfo info) {
    _provisioningSub?.close();
    _provisioningSub = _ref.listen<Map<String, TrackProvisioningState>>(
      provisioningControllerProvider,
      (previous, next) {
        void done() {
          _provisioningSub?.close();
          _provisioningSub = null;
        }

        if (state.nowPlaying?.recordingId != info.recordingId) return done();
        final result = next[info.recordingId];
        if (result == null) return;
        if (result.isAvailable && result.streamUrl != null) {
          done();
          // `_currentProgressive` záměrně zůstává: chyba ještě běžícího
          // progresivního spojení pak naváže hotovým souborem od stejného
          // místa (`_waitForAvailability` -> neprogresivní `_startStream`,
          // takže se to nezacyklí) a nespotřebuje automatický druhý pokus.
          if (!_player.playing || state.isBuffering) {
            _resumeAt = state.position;
            _resumeFor = info.recordingId;
            // Uživatelem pozastavená skladba se navázáním nesmí rozehrát.
            _startPausedWhenReady = !_player.playing;
            unawaited(_startStream(
              info,
              _streamUrlFor(info.recordingId),
              isProgressive: false,
            ));
          }
        } else if (result.status == 'PENDING' && previous?[info.recordingId]?.status != 'PENDING') {
          _awaitingProvisioning = true;
          // Stažení spadlo a jede znovu: dohraný buffer by skončil `completed`
          // a appka by skočila na další skladbu -- radši zastavit a počkat.
          _resumeAt = state.position;
          _resumeFor = info.recordingId;
          _startPausedWhenReady = !_player.playing; // pozastavená zůstane pozastavená
          unawaited(_player.stop());
          state = state.copyWith(isBuffering: true);
          _waitForAvailability(info);
        } else if (result.isFailed) {
          done();
          state = state.copyWith(isBuffering: false, error: result.error ?? 'obstarání skladby selhalo');
        }
      },
    );
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
    // Každé selhání na server (log) -- "občas se nepustí" jinak nejde dohledat.
    diagReport(
      'playback-error',
      '${info.recordingId} ${_currentLocal ? 'local' : _radioActive ? 'radio' : isProgressive ? 'progressive' : 'server'}'
          ' retry=${_sourceGen == _autoRetryGen} pos=${state.position.inSeconds}s: $error',
    );
    // Navázání nesmí pozastavenou skladbu rozehrát (záměr z `_startStream`
    // zůstává, jinak podle přehrávače).
    _startPausedWhenReady = _startPausedWhenReady || !_player.playing;
    // Offline soubor nejde přečíst -> zkusit server (bez toho by nebylo na
    // co čekat: obstarávání o skladbě nemusí nic vědět).
    final fromLocal = _currentLocal && !isProgressive;
    if (fromLocal && _prefetched.remove(info.recordingId) != null) {
      unawaited(PrefetchCache.remove(info.recordingId));
    }
    if (fromLocal && isSpokenId(info.recordingId)) {
      // Stažená epizoda nejde přečíst -> hrát ze serveru (obstarávání se
      // mluveného slova netýká), od stejného místa.
      _currentLocal = false;
      _resumeAt = state.position;
      _resumeFor = info.recordingId;
      unawaited(_startStream(info, _streamUrlFor(info.recordingId), isProgressive: false));
      return;
    }
    if (isProgressive || fromLocal) {
      _currentLocal = false;
      _awaitingProvisioning = true;
      // Navázat tam, kde to spadlo (chyba uprostřed hraní).
      _resumeAt = state.position;
      _resumeFor = info.recordingId;
      state = state.copyWith(isBuffering: true);
      if (fromLocal) {
        final provisioning = _ref.read(provisioningControllerProvider.notifier);
        provisioning.awaitedRecordingId = info.recordingId;
        unawaited(provisioning.provision(info.recordingId, interactive: true));
      }
      // Už AVAILABLE -> `_waitForAvailability` hned naváže hotovým souborem.
      _waitForAvailability(info);
      return;
    }
    // Hotový soubor ze serveru: výpadek sítě uprostřed hraní -> jednou sám
    // navázat od místa výpadku (dřív chyba a "Zkusit znovu" od 0:00).
    _resumeAt = state.position;
    _resumeFor = info.recordingId;
    if (_sourceGen != _autoRetryGen) {
      debugPrint('AudioPlayerController: přehrání selhalo ($error), zkouším znovu');
      _awaitingProvisioning = true; // play/pause mezitím jen jako záměr
      state = state.copyWith(isBuffering: true);
      final gen = _sourceGen;
      // Chvilka na obnovení spojení -- hned by druhý pokus spadl taky.
      Timer(const Duration(seconds: 2), () {
        if (state.nowPlaying?.recordingId != info.recordingId) {
          // Jiná skladba: pozice této už nesmí platit, až na ni zase dojde.
          if (_resumeFor == info.recordingId) {
            _resumeAt = null;
            _resumeFor = null;
          }
          return;
        }
        if (gen != _sourceGen) return;
        _autoRetryGen = _sourceGen + 1; // `_startStream` ji hned zvýší
        _autoRetryFrom = null;
        unawaited(_startStream(
          info,
          _streamUrlFor(info.recordingId),
          isProgressive: false,
        ));
      });
      return;
    }
    // Ani druhý pokus: server možná soubor zrovna vyměnil / ověřuje / ztratil
    // (409 "zavolej znovu provision") a appka ho má pořád za hotový. Jednou
    // ho znovu obstarat a počkat -- dřív rovnou "Nepodařilo se přehrát".
    if (_reprovisioned != info.recordingId && !isSpokenId(info.recordingId)) {
      _reprovisioned = info.recordingId;
      _stopRadio();
      _awaitingProvisioning = true;
      state = state.copyWith(isBuffering: true);
      final provisioning = _ref.read(provisioningControllerProvider.notifier);
      provisioning.awaitedRecordingId = info.recordingId;
      unawaited(provisioning.provision(info.recordingId, interactive: true).then((_) {
        if (state.nowPlaying?.recordingId == info.recordingId) _waitForAvailability(info);
      }));
      return;
    }
    _priming = false;
    _awaitingProvisioning = false;
    // Rádio by jinak dál tikalo/restartovalo a hrálo pod chybou.
    _stopRadio();
    debugPrint('AudioPlayerController: přehrání selhalo: $error');
    state = state.copyWith(isBuffering: false, error: 'Nepodařilo se přehrát');
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
  /// `false` = nepovedlo se (opakování řídí `_retryAccent`).
  Future<bool> _extractAccentColor(String recordingId, String artworkUrl) async {
    final color = await extractAccentColor(artworkUrl);
    if (color == null) return false;
    _accentColorCache[recordingId] = color;
    if (state.nowPlaying?.recordingId == recordingId) {
      state = state.copyWith(accentColor: color);
    }
    return true;
  }

  AppLifecycleListener? _lifecycle;

  /// Hrající skladba ještě nemá svou barvu (drží se barva předchozí) --
  /// spočítat znovu.
  void _refreshAccentIfMissing() {
    // Rozposlouchaná alba/playlisty z jiných zařízení.
    unawaited(_ref.read(collectionProgressProvider.notifier).refresh());
    // Obal hrající skladby: nepovedené analýzy (tóny, charakter) znovu.
    final art = state.nowPlaying?.artworkUrl;
    if (art != null) {
      resetCoverRetries();
      if (_ref.read(coverCharacterProvider(art)).valueOrNull == null) _ref.invalidate(coverCharacterProvider(art));
      if ((_ref.read(supportTonesProvider(art)).valueOrNull ?? const []).isEmpty) {
        _ref.invalidate(supportTonesProvider(art));
      }
    }
    final info = state.nowPlaying;
    if (info == null || _accentColorCache.containsKey(info.recordingId)) return;
    unawaited(_resolveArtworkAndAccent(info));
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
  Future<void> _resolveArtworkAndAccent(NowPlayingInfo info, {int attempt = 0}) async {
    // Skladba s albem: VŽDY obal jejího alba -- obrázek předaný z obrazovky,
    // odkud se hrálo (třeba fotka interpreta na jeho stránce), byl zavádějící
    // a počítaly se z něj i barvy (živě: špatný obal a barvy na iPhonu).
    var artworkUrl = _artworkCache[info.recordingId];
    try {
      if (artworkUrl == null && info.releaseId != null) {
        artworkUrl = await _ref.read(recordingArtworkProvider((releaseId: info.releaseId, artistId: null)).future);
      }
      artworkUrl ??= info.artworkUrl;
      if (artworkUrl == null && info.artistId != null) {
        artworkUrl = await _ref.read(recordingArtworkProvider((releaseId: null, artistId: info.artistId)).future);
      }
    } catch (e) {
      debugPrint('AudioPlayerController: obal se nedohledal ($e)');
    }
    if (artworkUrl == null) {
      // Obal se nedohledal (síť na zamčeném telefonu) -- zkusit znovu, jinak
      // by skladba zůstala bez obalu i barvy.
      _retryAccent(info, attempt);
      return;
    }
    _artworkCache[info.recordingId] = artworkUrl;

    if (info.artworkUrl != artworkUrl && state.nowPlaying?.recordingId == info.recordingId) {
      final updatedInfo = NowPlayingInfo(
        recordingId: info.recordingId,
        title: info.title,
        artistName: info.artistName,
        artistId: info.artistId,
        releaseId: info.releaseId,
        artworkUrl: artworkUrl,
        groupId: info.groupId,
        groupLabel: info.groupLabel,
        durationMs: info.durationMs,
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
      final ok = await _extractAccentColor(info.recordingId, artworkUrl);
      if (!ok) _retryAccent(info, attempt);
    }
  }

  /// Barva/obal hrající skladby se nepovedly (typicky automatický přechod na
  /// zamčeném telefonu -- iOS/Safari na pozadí obrázky nedekóduje): znovu po
  /// 4 s, 15 s a 60 s, dokud skladba hraje. Dřív jen jednou po 4 s a pak
  /// zůstala cizí (nebo výchozí fialová) barva až do reloadu.
  static const _accentRetryDelays = [Duration(seconds: 4), Duration(seconds: 15), Duration(seconds: 60)];

  void _retryAccent(NowPlayingInfo info, int attempt) {
    if (attempt >= _accentRetryDelays.length) return;
    Timer(_accentRetryDelays[attempt], () {
      if (state.nowPlaying?.recordingId != info.recordingId || _accentColorCache.containsKey(info.recordingId)) return;
      unawaited(_resolveArtworkAndAccent(state.nowPlaying!, attempt: attempt + 1));
    });
  }

  /// Zavřít přehrávač (stažení mini přehrávače dolů): zastavit, vyprázdnit
  /// frontu a zapomenout uloženou relaci -- po znovuotevření appky se
  /// neobnoví. Nastavení (hlasitost, rychlost, opakování...) zůstává.
  Future<void> dismiss() async {
    if (state.nowPlaying == null) return;
    _scrobbleId = null;
    _stopRadio();
    // Zavřený přehrávač nemá co uspávat -- jinak by časovač později tiše
    // ztlumil hlasitost další, nově puštěné skladby.
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _cancelFade();
    _restoredIdle = false;
    // Zavřeno během načítání / čekání na druhý pokus: nic z toho už nesmí
    // doběhnout (a Play/Pause nesmí zůstat jen "záměrem").
    _provisioningSub?.close();
    _provisioningSub = null;
    _awaitingProvisioning = false;
    _priming = false;
    _startPausedWhenReady = false;
    _sourceGen++;
    _resumeAt = null;
    _resumeFor = null;
    _realtime.playbackPause();
    try {
      await _player.stop();
    } catch (_) {}
    state = AudioPlayerState(
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      repeatMode: state.repeatMode,
      speed: state.speed,
      volume: state.volume,
      recentlyPlayed: state.recentlyPlayed,
      normalizationEnabled: state.normalizationEnabled,
    );
    _lastPersistKey = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionPrefKey);
    } catch (_) {}
  }

  /// Pokračování z pauzy v albu/playlistu, ve kterém uživatel mezitím
  /// pokročil na JINÉM zařízení: navázat tam (novější pozice), ne pustit
  /// starou a přepsat s ní tu novou. `true` = navázáno.
  Future<bool> _continueFromOtherDevice() async {
    final route = _queueContext;
    final np = state.nowPlaying;
    if (np == null || _player.playing || !CollectionProgressController.isCollection(route)) return false;
    final progress = _ref.read(collectionProgressProvider.notifier);
    // PC (ne Safari na iPhonu -- tam by čekání na síť zablokovalo přehrání
    // z klepnutí; stav se tam obnoví při návratu do appky): krátce ověřit
    // se serverem, i když se okno mezitím neschovalo.
    if (!_nativeHls) {
      await progress.refresh().timeout(const Duration(milliseconds: 1500), onTimeout: () {});
    }
    final other = progress.newerFromOtherDevice(route!);
    if (other == null) return false;
    final samePlace =
        other.recordingId == np.recordingId && (other.positionMs - state.position.inMilliseconds).abs() < 8000;
    if (samePlace) return false;
    final index = state.queue.indexWhere((i) => i.recordingId == other.recordingId);
    if (index < 0) return false;
    _restoredIdle = false;
    _resumeAt = Duration(milliseconds: other.positionMs);
    _resumeFor = other.recordingId;
    _ref.read(playerNoticeProvider.notifier).state = 'Navazuju tam, kde jsi skončil na jiném zařízení';
    await _playAtIndex(index);
    return true;
  }

  Future<void> togglePlayPause() async {
    if (state.nowPlaying == null) return;
    // Skladba se teprve obstarává -- `_player` nechat být (rozehrál by zbytek
    // předchozí skladby / pauza by na webu rozbila tiché odemknutí). Jen
    // přepnout záměr: po načtení hrát, nebo zůstat pozastavená.
    if (!_loadingTrack && state.error != null && !_player.playing) return retryCurrent();
    if (_loadingTrack) {
      _startPausedWhenReady = !_startPausedWhenReady;
      return;
    }
    if (!_player.playing && await _continueFromOtherDevice()) return;
    if (_restoredIdle) {
      // Obnovený přehrávač po znovuotevření appky -- zdroj ještě není
      // načtený; spustit skladbu od uložené pozice.
      _restoredIdle = false;
      _resumeAt = state.position;
      _resumeFor = state.nowPlaying!.recordingId;
      await _playAtIndex(state.queueIndex);
      return;
    }
    if (_player.playing) {
      await _player.pause();
      _realtime.playbackPause();
      _maybePersistSession(state, force: true);
      _maybeSaveSpokenProgress(force: true);
    } else if (_radioActive && !_appVisible) {
      // Zamčená obrazovka / appka na pozadí: iOS webové appce NEdovolí
      // spustit nový zdroj zvuku -- jen pokračovat ve stávajícím streamu
      // (živě: po pauze ze zamčené obrazovky nešlo znovu pustit). Zastaralý
      // stream po návratu do appky vyřeší hlídač v `_pollRadio`.
      _radioPausedAt = null;
      await _player.play();
      _realtime.playbackPlay(state.nowPlaying!.recordingId, positionMs: state.position.inMilliseconds);
    } else if (_radioActive) {
      // Po pauze navázat novým streamem (starý mohl vypršet / Safari drží
      // zastaralý buffer živého streamu).
      _restartRadio(state.position);
      _realtime.playbackPlay(state.nowPlaying!.recordingId, positionMs: state.position.inMilliseconds);
    } else {
      await _player.play();
      _realtime.playbackPlay(state.nowPlaying!.recordingId, positionMs: state.position.inMilliseconds);
    }
  }

  Future<void> seek(Duration position) async {
    if (_radioActive) {
      // Živý stream převíjet nejde -- nový stream od dané pozice skladby.
      _restartRadio(position);
      _realtime.playbackSeek(position.inMilliseconds);
      return;
    }
    await _player.seek(position);
    _realtime.playbackSeek(position.inMilliseconds);
    _maybePersistSession(state.copyWith(position: position), force: true);
    _mediaSession.setPosition(position: position, duration: state.duration, speed: state.speed);
  }

  void _onPlayerStateChanged(PlayerState playerState) {
    if (_priming) {
      // Stav tichého "odemykacího" zvuku není stav skladby -- UI dál ukazuje
      // načítání a jeho konec nesmí spustit `next()`.
      state = state.copyWith(isPlaying: false, isBuffering: true);
      return;
    }
    // Pozastaveně načtená skladba se teď opravdu rozehrála -> nový poslech.
    if (_scrobbleOnPlay case final id? when playerState.playing) {
      _scrobbleOnPlay = null;
      if (state.nowPlaying?.recordingId == id) _beginScrobble(id);
    }
    // Živý stream (rádio) přehrávač často hlásí trvale jako "loading/
    // buffering" (nekonečná délka) -- tlačítko pauzy pak bylo zablokované
    // točícím se kolečkem a nešlo zastavit (živě nahlášeno). V rádiu se
    // načítání ukazuje jen do prvního zvuku.
    final loading = playerState.processingState == ProcessingState.loading ||
        playerState.processingState == ProcessingState.buffering;
    state = state.copyWith(
      isPlaying: playerState.playing,
      isBuffering: _awaitingProvisioning || (loading && !(_radioActive && _player.position > Duration.zero)),
    );
    if (_radioActive) {
      // Spuštění mimo appku (zamčená obrazovka, sluchátka) obejde
      // `togglePlayPause` a Safari pustí starý živý playlist -- po delší
      // pauze proto vždy nový stream.
      if (!playerState.playing) {
        _radioPausedAt ??= DateTime.now();
      } else if (_radioPausedAt case final pausedAt?) {
        _radioPausedAt = null;
        // Jen s appkou na obrazovce -- na zamčené by nový stream iOS zakázal.
        if (_appVisible && DateTime.now().difference(pausedAt) > const Duration(minutes: 1)) {
          debugPrint('AudioPlayerController: rádio po dlouhé pauze, nový stream');
          _restartRadio(state.position);
          return;
        }
      }
    }
    if (playerState.processingState == ProcessingState.completed && _radioActive) {
      // Živý stream "skončil" -- u rádia to znamená spadlé spojení, ne konec
      // fronty (ten server nepošle, dokud je co hrát). Navázat od aktuální
      // pozice; opravdový konec = poslední skladba je dohraná.
      final dur = state.duration;
      final atEnd = !state.hasNext && dur != null && state.position >= dur - const Duration(seconds: 3);
      if (!atEnd && DateTime.now().difference(_radioLastRestart) > const Duration(seconds: 5)) {
        _radioLastRestart = DateTime.now();
        debugPrint('AudioPlayerController: rádio spadlo, navazuji od ${state.position}');
        _restartRadio(state.position);
      }
      return;
    }
    if (playerState.processingState == ProcessingState.completed && _awaitingProvisioning) {
      // Dohrál zbytek starého / progresivního zdroje, zatímco se aktuální
      // skladba obstarává -- to není konec skladby, na další nepřeskakovat.
      return;
    }
    if (playerState.processingState == ProcessingState.completed) {
      // Právě přepnuto dřív (`_maybeAdvanceEarly`) -- `completed` patří staré
      // skladbě, jinak by se přeskočilo o dvě.
      final early = _earlyAdvancedAt;
      if (early != null && DateTime.now().difference(early) < const Duration(seconds: 3)) return;
      if (state.repeatMode == RepeatMode.one) {
        unawaited(_replayCurrent());
      } else {
        // Doposlouchané album/playlist -- už nenabízet "Pokračovat".
        final route = _queueContext;
        if (state.nextIndex == null && CollectionProgressController.isCollection(route)) {
          _ref.read(collectionProgressProvider.notifier).clear(route!);
        }
        // Kniha se ještě stahuje: mezitím dorazily další kapitoly -> přidat.
        if (state.nextIndex == null && spokenParts(state.nowPlaying?.recordingId ?? '') != null) {
          unawaited(_continueSpokenBook());
          return;
        }
        unawaited(next(auto: true));
      }
    }
  }

  // --- Scrobbling (poslechy pro osobní mixy + ListenBrainz) ---------------

  String? _scrobbleId;
  DateTime? _scrobbleStartedAt;
  Duration _scrobbleAccum = Duration.zero;
  Duration? _scrobbleLastPos;
  bool _scrobbled = false;
  bool _heardMarked = false;

  /// Nové přehrávání skladby (i opakované přehrání téže) = nový poslech.
  void _beginScrobble(String recordingId) {
    _finishScrobble();
    _scrobbleId = recordingId;
    _scrobbleStartedAt = DateTime.now();
    _scrobbleAccum = Duration.zero;
    _scrobbleLastPos = null;
    _scrobbleLastAt = null;
    _scrobbleDuration = null;
    _scrobbled = false;
    _heardMarked = false;
    unawaited(_ref.read(listensRepositoryProvider).playingNow(recordingId).catchError((Object _) {}));
    // Poslechy, které dřív neprošly (bez signálu), zkusit znovu.
    unawaited(_ref.read(listensRepositoryProvider).flushPending());
  }

  /// Předchozí skladba skončila / přeskočila se: když poslední zprávy
  /// o pozici nedorazily (iOS na pozadí je posílá řidčeji), dopočítat
  /// odehraný čas z poslední známé pozice a skutečně uplynulého času.
  void _finishScrobble() {
    final id = _scrobbleId;
    final started = _scrobbleStartedAt;
    final lastPos = _scrobbleLastPos;
    if (id == null || started == null || _scrobbled || lastPos == null) return;
    final wall = DateTime.now().difference(started);
    // Nikdy víc, než kolik reálně uběhlo, ani víc než kam skladba došla.
    final played = lastPos < wall ? lastPos : wall;
    if (played > _scrobbleAccum) _scrobbleAccum = played;
    _submitIfHeard(id, _scrobbleDuration);
  }

  DateTime? _scrobbleLastAt;
  Duration? _scrobbleDuration;

  /// Počítá jen skutečně odehraný čas (posun vpřed přes seek se nepočítá).
  /// Poslech se nahlásí po polovině délky nebo 4 minutách -- standardní
  /// pravidlo ListenBrainz/Last.fm; skladby kratší než 30 s se nehlásí.
  void _trackScrobble(Duration position) {
    final id = _scrobbleId;
    if (id == null || (_scrobbled && _heardMarked) || state.nowPlaying?.recordingId != id) return;
    final last = _scrobbleLastPos;
    final lastAt = _scrobbleLastAt;
    final now = DateTime.now();
    _scrobbleLastPos = position;
    _scrobbleLastAt = now;
    _scrobbleDuration = state.duration ?? _scrobbleDuration;
    if (last == null || !_player.playing) return;
    final delta = position - last;
    if (delta <= Duration.zero) return;
    // Na pozadí (zamčený iPhone) chodí pozice řidčeji -- delší skok se
    // počítá, když odpovídá skutečně uplynulému času; skok dál než uběhlo
    // je přetočení a nepočítá se. Dřív se cokoli nad 3 s zahodilo a poslech
    // z kapsy se nezapsal (živě: tátovy skladby na cestě).
    final wall = lastAt == null ? Duration.zero : now.difference(lastAt);
    final plausible = delta <= const Duration(seconds: 3) ||
        (delta <= wall + const Duration(seconds: 2) && delta <= const Duration(minutes: 2));
    if (!plausible) return;
    _scrobbleAccum += delta;
    final duration = state.duration;
    // Poslechnuto celé (>= 90 % délky skutečně odehráno) -> trvalá značka.
    if (!_heardMarked && duration != null && _scrobbleAccum >= duration * 0.9) {
      _heardMarked = true;
      unawaited(_ref.read(heardProvider.notifier).mark(id));
    }
    _submitIfHeard(id, duration);
  }

  /// Nahlásí poslech, je-li odehráno aspoň půl skladby nebo 4 minuty.
  void _submitIfHeard(String id, Duration? duration) {
    if (_scrobbled) return;
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
          context: _queueContext,
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
    _lifecycle?.dispose();
    _stallWatch?.cancel();
    _sleepTimer?.cancel();
    _fadeTimer?.cancel();
    _gainRampTimer?.cancel();
    _radioPoll?.cancel();
    _radioTick?.cancel();
    _provisioningSub?.close();
    _player.dispose();
    super.dispose();
  }
}

/// A-B opakování aktuální skladby: `a` nastaveno, `b` ještě ne = čeká se na
/// druhý bod; obojí = smyčka běží. `null` = vypnuto.
typedef AbRepeat = ({String recordingId, Duration a, Duration? b});

final abRepeatProvider = StateProvider<AbRepeat?>((ref) => null);

/// Krátké oznámení přehrávače pro UI (snackbar), např. navázání z jiného
/// zařízení. UI ho zobrazí a vynuluje.
final playerNoticeProvider = StateProvider<String?>((ref) => null);

/// Všechno ze stavu přehrávače kromě pozice -- pro `select` u widgetů,
/// které se mají přestavět při změně skladby/stavu, ale ne 5x za vteřinu
/// s každým posunem pozice (tu si kreslí jen vlnovka / časy).
Object playerChromeKey(AudioPlayerState s) => (
      s.nowPlaying,
      s.accentColor,
      s.duration,
      s.error,
      s.isBuffering,
      s.isPlaying,
      s.queue,
      s.queueIndex,
      s.shuffleEnabled,
      s.shuffleOrder,
      s.repeatMode,
      s.speed,
      s.volume,
      s.sleepTimerEndAt,
      s.queueSourceLabel,
      s.normalizationEnabled,
      s.recentlyPlayed,
    );

final audioPlayerControllerProvider = StateNotifierProvider<AudioPlayerController, AudioPlayerState>((ref) {
  return AudioPlayerController(ref.watch(realtimeClientProvider), ref);
});

/// Úsek nepřetržitého streamu: od `startMs` (čas streamu) hraje skladba
/// `recordingId` od svého `offsetMs`; `trackMs` = délka celé skladby.
class _RadioSegment {
  const _RadioSegment({required this.recordingId, required this.startMs, required this.offsetMs, this.trackMs});

  final String recordingId;
  final double startMs;
  final double offsetMs;
  final double? trackMs;
}
