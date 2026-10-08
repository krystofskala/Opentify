import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart' show ApiException;
import '../../core/config.dart';
import '../../core/device_token.dart' show withDeviceToken;
import '../../core/realtime_event.dart' show UnknownEvent;
import '../../state/audio_player_controller.dart' show NowPlayingInfo;
import '../../state/providers.dart';
import 'podcast_data.dart' show PodcastSearchResult;

/// Audioknihy (backend app/routes/spoken.py) -- odděleně od hudby.
class SpokenRelease {
  const SpokenRelease({
    required this.infohash,
    required this.title,
    this.sizeBytes,
    required this.seeders,
    this.coverUrl,
    this.added,
    this.bookId,
    this.status,
    this.source = 'sktorrent',
    this.ref,
    this.files,
    this.uploader,
    this.durationText,
    this.totalParts,
    this.complete = true,
    this.kind,
  });

  factory SpokenRelease.fromJson(Map<String, dynamic> j) => SpokenRelease(
        infohash: j['infohash'] as String? ?? '',
        source: j['source'] as String? ?? 'sktorrent',
        ref: j['ref'] as String?,
        files: (j['files'] as num?)?.toInt(),
        title: j['title'] as String,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
        seeders: (j['seeders'] as num?)?.toInt() ?? 0,
        coverUrl: spokenCoverUrl(j['coverUrl'] as String?),
        added: j['added'] as String?,
        bookId: j['bookId'] as String?,
        status: j['status'] as String?,
        uploader: j['uploader'] as String?,
        durationText: j['durationText'] as String?,
        totalParts: (j['totalParts'] as num?)?.toInt(),
        complete: j['complete'] as bool? ?? true,
        kind: j['kind'] as String?,
      );

  final String infohash;
  final String title;
  final int? sizeBytes;
  final int seeders;
  final String? coverUrl;
  final String? added;
  final String? bookId;
  final String? status;

  /// sktorrent (česky) | slskd (Soulseek, typicky anglicky) | youtube (odkaz na
  /// video) | rozhlas (archiv Českého rozhlasu).
  final String source;
  final String? ref;
  final int? files;

  /// YouTube: kanál a délka videa (místo velikosti a zdrojů).
  final String? uploader;
  final String? durationText;

  /// Český rozhlas: kolik dílů seriálu vůbec bylo (`files` = kolik jich jde
  /// stáhnout) -- u části vypršela práva.
  final int? totalParts;
  final bool complete;

  /// book | drama (rozhlasová hra) -- u rozhlasu podle pořadu.
  final String? kind;

  bool get isYoutube => source == 'youtube';
  bool get isRozhlas => source == 'rozhlas';
}

class SpokenProgress {
  const SpokenProgress({required this.fileId, required this.positionMs, required this.finished, this.updatedAt});

  factory SpokenProgress.fromJson(Map<String, dynamic> j) => SpokenProgress(
        fileId: j['fileId'] as String,
        positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
        finished: j['finished'] as bool? ?? false,
        updatedAt: j['updatedAt'] == null ? null : DateTime.tryParse(j['updatedAt'] as String)?.toLocal(),
      );

  final DateTime? updatedAt;
  final String fileId;
  final int positionMs;
  final bool finished;
}

class SpokenFileItem {
  const SpokenFileItem({required this.id, required this.position, this.title, this.durationMs, this.chapters = const []});

  factory SpokenFileItem.fromJson(Map<String, dynamic> j) => SpokenFileItem(
        id: j['id'] as String,
        position: (j['position'] as num?)?.toInt() ?? 0,
        title: j['title'] as String?,
        durationMs: (j['durationMs'] as num?)?.toInt(),
        chapters: [
          for (final c in j['chapters'] as List<dynamic>? ?? const [])
            (title: (c as Map<String, dynamic>)['title'] as String? ?? '', startMs: (c['startMs'] as num?)?.toInt() ?? 0),
        ],
      );

  final String id;
  final int position;
  final String? title;
  final int? durationMs;
  final List<({String title, int startMs})> chapters;
}

class SpokenBook {
  const SpokenBook({
    required this.id,
    required this.title,
    this.author,
    this.narrator,
    this.coverUrl,
    required this.releaseTitle,
    this.sizeBytes,
    required this.status,
    required this.downloadProgress,
    this.error,
    this.durationMs,
    this.progress,
    this.files = const [],
    this.playableFiles = 0,
    this.mine = true,
    this.createdAt,
    this.kind = 'book',
    this.seriesName,
    this.seriesNumber,
  });

  factory SpokenBook.fromJson(Map<String, dynamic> j) {
    final p = j['progress'];
    return SpokenBook(
      id: j['id'] as String,
      title: j['title'] as String? ?? '',
      author: j['author'] as String?,
      narrator: j['narrator'] as String?,
      coverUrl: spokenCoverUrl(j['coverUrl'] as String?),
      releaseTitle: j['releaseTitle'] as String? ?? '',
      sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
      status: j['status'] as String? ?? 'pending',
      downloadProgress: ((j['downloadProgress'] ?? (p is num ? p : 0)) as num).toDouble(),
      error: j['error'] as String?,
      durationMs: (j['durationMs'] as num?)?.toInt(),
      progress: p is Map<String, dynamic> ? SpokenProgress.fromJson(p) : null,
      files: [for (final f in j['files'] as List<dynamic>? ?? const []) SpokenFileItem.fromJson(f as Map<String, dynamic>)],
      playableFiles: (j['playableFiles'] as num?)?.toInt() ?? (j['files'] as List<dynamic>? ?? const []).length,
      mine: j['mine'] as bool? ?? true,
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
      kind: j['kind'] as String? ?? 'book',
      seriesName: j['seriesName'] as String?,
      seriesNumber: j['seriesNumber'] as num?,
    );
  }

  final String id;
  final String title;
  final String? author;
  final String? narrator;
  final String? coverUrl;
  final String releaseTitle;
  final int? sizeBytes;

  /// pending / downloading / importing / ready / failed
  final String status;
  final double downloadProgress;
  final String? error;
  final int? durationMs;
  final SpokenProgress? progress;
  final List<SpokenFileItem> files;

  /// Kolik částí už jde přehrát (stahuje se popořadě, první kapitola hned).
  final int playableFiles;

  /// O knihu jsem žádal, nebo ji poslouchám. Ostatní knihy na serveru jsou
  /// na Domů ve vlastní sekci "Knihy ostatních".
  final bool mine;

  /// Kdy se kniha objevila na serveru (řazení "Přidáno").
  final DateTime? createdAt;

  /// book | drama -- rozhlasová hra má na Domů a v Knihovně vlastní místo.
  final String kind;
  bool get isDrama => kind == 'drama';

  /// Řada a díl (Wikidata, doplňuje server postupně) -- "Sága o zaklínači · díl 3".
  final String? seriesName;
  final num? seriesNumber;

  String? get seriesLine {
    final n = seriesNumber;
    if (seriesName == null || seriesName!.isEmpty) return null;
    if (n == null) return seriesName;
    final num = n == n.roundToDouble() ? '${n.toInt()}' : '$n'.replaceAll('.', ',');
    return '$seriesName · díl $num';
  }

  bool get isReady => status == 'ready';

  /// Hraje už během stahování -- jakmile dorazí první kapitola.
  bool get canPlay => isReady || playableFiles > 0;
  bool get isWorking => status == 'pending' || status == 'downloading' || status == 'importing';
  bool get inProgress => progress != null && !progress!.finished;

  String get byline => [
        if (author != null) author!,
        if (narrator != null) 'čte $narrator',
      ].join(' · ');
}

/// `sp:<kniha>:<soubor>` -- id položky ve frontě přehrávače (viz
/// `AudioPlayerController.isSpokenId`).
String spokenQueueId(String bookId, String fileId) => 'sp:$bookId:$fileId';

/// Fronta přehrávače z knihy: všechny soubory v pořadí.
List<NowPlayingInfo> spokenQueue(SpokenBook book) => [
      for (final f in book.files)
        NowPlayingInfo(
          recordingId: spokenQueueId(book.id, f.id),
          title: f.title ?? book.title,
          artistName: book.title,
          artworkUrl: book.coverUrl,
        ),
    ];

String spokenStreamUrl(String baseUrl, String fileId) => withDeviceToken('$baseUrl/spoken/files/$fileId/stream');

/// Obal přichází jako cesta na našem API (spoken/cover/<hash>) -- appka se
/// na SkTorrent nepřipojuje sama. Klíč v ?t= kvůli nativnímu načítání.
String? spokenCoverUrl(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http')) return path;
  return withDeviceToken('${AppConfig.apiBaseUrl}/$path');
}

String formatSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} GB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}

String formatHours(int? ms) {
  if (ms == null || ms <= 0) return '';
  final minutes = ms ~/ 60000;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h > 0 ? '$h h $m min' : '$m min';
}

final spokenBooksProvider = FutureProvider.autoDispose<List<SpokenBook>>((ref) async {
  // Změna stavu stahování (WS `spoken.book`) -> načíst znovu.
  ref.watch(spokenEventsProvider);
  final json = await ref.watch(apiClientProvider).getJson('/spoken/books');
  return [for (final b in json['books'] as List<dynamic>? ?? const []) SpokenBook.fromJson(b as Map<String, dynamic>)];
});

/// Pořadí a viditelnost sekcí Domů mluveného slova (Profil › Domů ›
/// Upravit Domů mluveného slova). Při chybě výchozí (všechno, `null`).
final spokenHomeLayoutProvider = FutureProvider.autoDispose<List<({String id, bool visible})>?>((ref) async {
  try {
    final json = await ref.watch(apiClientProvider).getJson('/spoken/home/layout');
    return [
      for (final s in (json['sections'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
        (id: s['id'] as String, visible: s['visible'] as bool? ?? true),
    ];
  } catch (_) {
    return null;
  }
});

final spokenBookProvider = FutureProvider.autoDispose.family<SpokenBook, String>((ref, id) async {
  ref.watch(spokenEventsProvider);
  return SpokenBook.fromJson(await ref.watch(apiClientProvider).getJson('/spoken/books/$id'));
});

typedef SpokenSearchResult = ({List<SpokenRelease> releases, bool loginConfigured});

final spokenSearchProvider = FutureProvider.autoDispose.family<SpokenSearchResult, String>((ref, q) async {
  // Bez sledování událostí stahování: každá zpráva o průběhu (každých pár
  // sekund) by hledání venku spustila znovu a zrušila -- výsledky se pořád
  // načítaly a ze Soulseeku nedorazily nikdy (7. 10.).
  final json = await ref.watch(apiClientProvider).getJson('/spoken/search', query: {'q': q});
  return (
    releases: [for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>)],
    loginConfigured: json['loginConfigured'] as bool? ?? false,
  );
});

typedef SpokenPerson = ({
  String name,
  String role,
  List<SpokenBook> books,
  List<SpokenRelease> releases,
  bool loginConfigured,
  String? image,
  String? bio,
  String? description,
});

/// Stránka autora / interpreta (čte): jeho knihy na serveru a další vydání
/// ke stažení. `role`: author | narrator.
final spokenPersonProvider =
    FutureProvider.autoDispose.family<SpokenPerson, ({String name, String role})>((ref, who) async {
  // Bez sledování událostí stahování: každá zpráva o průběhu (každých pár
  // sekund) by hledání venku spustila znovu a zrušila -- výsledky se pořád
  // načítaly a ze Soulseeku nedorazily nikdy (7. 10.).
  final json =
      await ref.watch(apiClientProvider).getJson('/spoken/person', query: {'name': who.name, 'role': who.role});
  return (
    name: json['name'] as String? ?? who.name,
    role: json['role'] as String? ?? who.role,
    books: [for (final b in json['books'] as List<dynamic>? ?? const []) SpokenBook.fromJson(b as Map<String, dynamic>)],
    releases: [
      for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>),
    ],
    loginConfigured: json['loginConfigured'] as bool? ?? false,
    image: json['image'] as String?,
    bio: json['bio'] as String?,
    description: json['description'] as String?,
  );
});

/// Hledání v tom, co už je na serveru: knihy a autoři / interpreti.
typedef SpokenLocalSearch = ({List<SpokenBook> books, List<({String name, String role, int books, String? image})> people});

final spokenLocalSearchProvider = FutureProvider.autoDispose.family<SpokenLocalSearch, String>((ref, q) async {
  // Jen naše databáze (rychlé, nic venku) -> stav stahování živě; jinak
  // "Na serveru" ukazovalo "Stahuje se · 12 %" u dávno hotové knihy.
  ref.watch(spokenEventsProvider);
  final json = await ref.watch(apiClientProvider).getJson('/spoken/search/local', query: {'q': q});
  return (
    books: [for (final b in json['books'] as List<dynamic>? ?? const []) SpokenBook.fromJson(b as Map<String, dynamic>)],
    people: [
      for (final p in (json['people'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
        (
          name: p['name'] as String? ?? '',
          role: p['role'] as String? ?? 'author',
          books: (p['books'] as num?)?.toInt() ?? 0,
          image: p['image'] as String?,
        ),
    ],
  );
});

/// Fotka autora / interpreta (Wikidata) pro náhled v hledání.
final spokenPersonImageProvider =
    FutureProvider.autoDispose.family<String?, ({String name, String role})>((ref, who) async {
  final json =
      await ref.watch(apiClientProvider).getJson('/spoken/person/wiki', query: {'name': who.name, 'role': who.role});
  return json['image'] as String?;
});

/// Popis knihy (Google Books, jen jistá shoda) -- načítá se zvlášť.
final spokenBookDescriptionProvider = FutureProvider.autoDispose.family<String?, String>((ref, id) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/books/$id/description');
  return json['description'] as String?;
});

/// Vydání knihy na stránce knihy: kopie na serveru (`bookId`) nebo vydání
/// ze SkTorrentu; `why` = proč je tak vysoko (doporučené první).
class SpokenEdition {
  SpokenEdition(this.json)
      : bookId = json['bookId'] as String?,
        status = json['status'] as String?,
        title = json['releaseTitle'] as String? ?? json['title'] as String? ?? '',
        narrator = json['narrator'] as String?,
        coverUrl = spokenCoverUrl(json['coverUrl'] as String?),
        why = [for (final w in json['why'] as List<dynamic>? ?? const []) w as String];

  final Map<String, dynamic> json;
  final String? bookId;
  final String? status;
  final String title;
  final String? narrator;
  final String? coverUrl;
  final List<String> why;

  bool get onServer => bookId != null;
  SpokenRelease get release => SpokenRelease.fromJson(json);
}

typedef SpokenWork = ({
  String title,
  String? author,
  String? year,
  String? seriesName,
  int? seriesNumber,
  String? summary,
  List<SpokenEdition> editions,
});

/// Stránka knihy (Knihovny.cz + všechna vydání). `null` = kniha v katalogu není.
final spokenWorkProvider =
    FutureProvider.autoDispose.family<SpokenWork?, ({String title, String author})>((ref, who) async {
  // Bez sledování událostí stahování: každá zpráva o průběhu (každých pár
  // sekund) by hledání venku spustila znovu a zrušila -- výsledky se pořád
  // načítaly a ze Soulseeku nedorazily nikdy (7. 10.).
  try {
    final json = await ref.watch(apiClientProvider).getJson('/spoken/work', query: {'title': who.title, 'author': who.author});
    final work = json['work'] as Map<String, dynamic>? ?? const {};
    final series = work['series'] as Map<String, dynamic>?;
    return (
      title: work['title'] as String? ?? who.title,
      author: work['author'] as String? ?? who.author,
      year: work['year'] as String?,
      seriesName: series?['name'] as String?,
      seriesNumber: (series?['number'] as num?)?.toInt(),
      summary: work['summary'] as String?,
      editions: [for (final e in json['editions'] as List<dynamic>? ?? const []) SpokenEdition(e as Map<String, dynamic>)],
    );
  } on ApiException catch (e) {
    if (e.statusCode == 404) return null;
    rethrow;
  }
});

/// Cesta na stránku knihy.
/// Díl řady: číslo (u prequelu i 0.5), rok a co z něj je na serveru
/// (`state`: ready | listening | finished | downloading | null = není).
typedef SpokenSeriesPart = ({String title, num? number, int? year, String? bookId, String? state});

/// Řada knihy z Wikidat a pořadí čtení (`loose` = díla řady bez čísla).
typedef SpokenSeries = ({String name, String author, List<SpokenSeriesPart> parts, List<SpokenSeriesPart> loose});

List<SpokenSeriesPart> _seriesParts(Object? list) => [
      for (final p in (list as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
        (
          title: p['title'] as String? ?? '',
          number: p['number'] as num?,
          year: (p['year'] as num?)?.toInt(),
          bookId: p['bookId'] as String?,
          state: p['state'] as String?,
        ),
    ];

/// Řada knihy (název + autor). Nenalezeno / Wikidata nedostupná = null.
final spokenSeriesProvider =
    FutureProvider.autoDispose.family<SpokenSeries?, ({String title, String author})>((ref, who) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/series', query: {'title': who.title, 'author': who.author});
  final s = json['series'] as Map<String, dynamic>?;
  if (s == null) return null;
  return (
    name: s['name'] as String? ?? '',
    author: s['author'] as String? ?? who.author,
    parts: _seriesParts(s['parts']),
    loose: _seriesParts(s['loose']),
  );
});

/// Celá řada ke stažení: komplety / sbírky ze SkTorrentu.
final spokenSeriesCollectionsProvider =
    FutureProvider.autoDispose.family<List<SpokenRelease>, ({String name, String author})>((ref, who) async {
  final json =
      await ref.watch(apiClientProvider).getJson('/spoken/series/collections', query: {'name': who.name, 'author': who.author});
  return [for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>)];
});

/// Stejné porovnání názvů jako server: bez diakritiky a interpunkce.
String spokenFoldTitle(String text) => spokenPersonRef(text).substring('author:'.length);

/// Díl řady, kterým je kniha ("Zaklínač I - Poslední přání" = Poslední přání).
SpokenSeriesPart? spokenSeriesPartOf(SpokenSeries s, String bookTitle) {
  final b = spokenFoldTitle(bookTitle);
  for (final p in s.parts) {
    final t = spokenFoldTitle(p.title);
    if (t.isEmpty) continue;
    if (b == t || (t.length >= 8 && ' $b '.contains(' $t '))) return p;
  }
  return null;
}

String spokenSeriesPath(String title, String author) =>
    Uri(path: '/spoken/series', queryParameters: {'title': title, 'author': author}).toString();

String spokenWorkPath(String title, String author) =>
    Uri(path: '/spoken/work', queryParameters: {'title': title, 'author': author}).toString();

/// Srdíčka mluveného slova: celé knihy (id) a autoři / interpreti
/// ("author:jméno" / "narrator:jméno", bez diakritiky -- skládá server).
typedef SpokenFavorites = ({Set<String> books, Set<String> people});

final spokenFavoritesProvider = FutureProvider.autoDispose<SpokenFavorites>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/favorites');
  return _favoritesFrom(json);
});

SpokenFavorites _favoritesFrom(Map<String, dynamic> json) => (
      books: {for (final b in json['books'] as List<dynamic>? ?? const []) b as String},
      people: {
        for (final p in (json['people'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()) p['ref'] as String,
      },
    );

/// Klíč osoby stejně jako server (`person_ref`): bez diakritiky, malá písmena.
String spokenPersonRef(String name, {bool narrator = false}) {
  const from = 'áäčďéěëíňóöřšťúůüýžÁÄČĎÉĚËÍŇÓÖŘŠŤÚŮÜÝŽøØłŁ';
  const to = 'aacdeeeinoorstuuuyzaacdeeeinoorstuuuyzoOlL';
  final buf = StringBuffer();
  for (final ch in name.split('')) {
    final i = from.indexOf(ch);
    buf.write(i >= 0 ? to[i] : ch);
  }
  final folded = buf.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');
  return '${narrator ? 'narrator' : 'author'}:$folded';
}

/// Srdíčko knihy / osoby zapnout nebo vypnout.
Future<void> setSpokenFavorite(WidgetRef ref, {String? bookId, String? person, bool narrator = false, required bool on}) async {
  await ref.read(apiClientProvider).putJson('/spoken/favorites', body: {
    'kind': bookId != null ? 'book' : 'person',
    if (bookId != null) 'ref': bookId,
    if (person != null) 'name': person,
    if (person != null) 'role': narrator ? 'narrator' : 'author',
    'on': on,
  });
  ref.invalidate(spokenFavoritesProvider);
  if (bookId != null) ref.invalidate(spokenBooksProvider);
}

/// Cesta na stránku autora / interpreta.
String spokenPersonPath(String name, {bool narrator = false}) =>
    Uri(path: '/spoken/person', queryParameters: {'name': name, if (narrator) 'role': 'narrator'}).toString();

/// Počítadlo událostí `spoken.book` z WS (stav stahování knihy).
final spokenEventsProvider = StreamProvider.autoDispose<int>((ref) {
  // Průběh stahování chodí každých pár sekund -- seznamy se nenačítají
  // znovu častěji než jednou za 5 s (appka "se pořád obnovovala a blikala").
  // Zpráva z doby čekání se pošle po jeho konci, poslední stav se neztratí.
  final controller = StreamController<int>();
  var n = 0;
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? pending;
  void emit() {
    pending = null;
    last = DateTime.now();
    controller.add(++n);
  }

  controller.add(n);
  final sub = ref.watch(realtimeClientProvider).events.listen((e) {
    if (e is! UnknownEvent || e.type != 'spoken.book') return;
    final wait = const Duration(seconds: 5) - DateTime.now().difference(last);
    if (wait <= Duration.zero) {
      emit();
    } else {
      pending ??= Timer(wait, emit);
    }
  });
  ref.onDispose(() {
    pending?.cancel();
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

/// `sizeBytes`: u výběru ze sbírky velikost jen vybraných souborů (limit
/// audioknih na člověka se počítá z ní, ne z celého vydání).
/// `true` = stahuje se; `false` = čeká na schválení správcem (velké vydání,
/// z internetu, přes týdenní limit).
Future<bool> acquireSpoken(WidgetRef ref, SpokenRelease r, {List<int>? files, String? folder, int? sizeBytes}) async {
  final json = await ref.read(apiClientProvider).postJson('/spoken/books', body: {
    if (files != null) 'files': files,
    if (folder != null && folder.isNotEmpty) 'folder': folder,
    'source': r.source,
    if (r.ref != null) 'ref': r.ref,
    if (r.infohash.isNotEmpty) 'infohash': r.infohash,
    'title': r.title,
    'sizeBytes': sizeBytes ?? r.sizeBytes,
  });
  ref.invalidate(spokenBooksProvider);
  ref.invalidate(spokenSearchProvider);
  ref.invalidate(spokenForeignSearchProvider);
  ref.invalidate(spokenRozhlasSearchProvider);
  return json['status'] != 'awaiting_approval';
}

/// Nepovedené stažení znovu (stejné vydání).
Future<void> retrySpokenBook(WidgetRef ref, String bookId) async {
  await ref.read(apiClientProvider).postJson('/spoken/books/$bookId/retry');
  ref.invalidate(spokenBookProvider(bookId));
  ref.invalidate(spokenBooksProvider);
}

/// Odebrat knihu, jejíž stažení selhalo.
Future<void> removeSpokenBook(WidgetRef ref, String bookId) async {
  await ref.read(apiClientProvider).deleteJson('/spoken/books/$bookId');
  ref.invalidate(spokenBooksProvider);
}

/// Hledání, které má Hledání (audioknihy) otevřít -- "Jiná verze" u knihy.
final spokenSearchRequestProvider = StateProvider<String?>((ref) => null);

/// Záloha za českou verzi: Soulseek (typicky anglické originály) -- zvlášť,
/// je pomalejší (~10 s).
final spokenForeignSearchProvider = FutureProvider.autoDispose.family<List<SpokenRelease>, String>((ref, q) async {
  // Bez sledování událostí stahování: každá zpráva o průběhu (každých pár
  // sekund) by hledání venku spustila znovu a zrušila -- výsledky se pořád
  // načítaly a ze Soulseeku nedorazily nikdy (7. 10.).
  final json = await ref.watch(apiClientProvider).getJson('/spoken/search/foreign', query: {'q': q});
  return [for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>)];
});

/// Archiv Českého rozhlasu (četba, rozhlasové hry) -- zvlášť, ať ostatní
/// hledání nečeká.
final spokenRozhlasSearchProvider = FutureProvider.autoDispose.family<List<SpokenRelease>, String>((ref, q) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/search/rozhlas', query: {'q': q});
  return [for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>)];
});

/// "Špatný obal": server ho zahodí a zkusí další zdroj (vložený v souboru,
/// obrázek ve složce, Google Books). `true` = našel jiný.
Future<bool> reportWrongBookCover(WidgetRef ref, String bookId) async {
  final json = await ref.read(apiClientProvider).postJson('/spoken/books/$bookId/wrong-cover');
  ref.invalidate(spokenBookProvider(bookId));
  ref.invalidate(spokenBooksProvider);
  return json['coverSource'] != null;
}

/// Ruční úprava názvu, autora a interpreta (import ani katalog ji nepřepíšou).
Future<void> setBookMeta(WidgetRef ref, String bookId, {required String title, String? author, String? narrator}) async {
  await ref.read(apiClientProvider).putJson('/spoken/books/$bookId/meta', body: {
    'title': title,
    'author': author,
    'narrator': narrator,
  });
  ref.invalidate(spokenBookProvider(bookId));
  ref.invalidate(spokenBooksProvider);
}

/// Vlastní obal knihy (automatika ho už nepřepíše).
Future<void> uploadBookCover(WidgetRef ref, String bookId, List<int> bytes, String filename) async {
  await ref.read(apiClientProvider).postMultipart('/spoken/books/$bookId/cover', fieldName: 'file', bytes: bytes, filename: filename);
  ref.invalidate(spokenBookProvider(bookId));
  ref.invalidate(spokenBooksProvider);
}

/// Audiokniha, nebo rozhlasová hra (ručně, platí pro všechny profily).
Future<void> setSpokenKind(WidgetRef ref, String bookId, String kind) async {
  await ref.read(apiClientProvider).putJson('/spoken/books/$bookId/kind', body: {'kind': kind});
  ref.invalidate(spokenBookProvider(bookId));
  ref.invalidate(spokenBooksProvider);
}

/// Kniha (složka) ve sbírce a její zvukové soubory (kapitoly).
typedef ReleaseFile = ({int index, String name, int size});
typedef ReleaseGroup = ({String folder, int size, List<ReleaseFile> files});

/// Obsah vydání před stažením (sbírka -> knihy). Chce účet SkTorrent.
Future<List<ReleaseGroup>> fetchReleaseGroups(WidgetRef ref, SpokenRelease r) async {
  final api = ref.read(apiClientProvider);
  final json = switch (r.source) {
    'slskd' => await api.getJson('/spoken/releases/foreign/files', query: {'ref': r.ref ?? ''}),
    'youtube' => await api.getJson('/spoken/releases/youtube/files', query: {'ref': r.ref ?? ''}),
    'rozhlas' => await api.getJson('/spoken/releases/rozhlas/files', query: {'ref': r.ref ?? ''}),
    _ => await api.getJson('/spoken/releases/${r.infohash}/files'),
  };
  return [
    for (final g in json['groups'] as List<dynamic>? ?? const [])
      (
        folder: (g as Map<String, dynamic>)['folder'] as String? ?? '',
        size: (g['size'] as num?)?.toInt() ?? 0,
        files: [
          for (final f in g['files'] as List<dynamic>? ?? const [])
            (
              index: ((f as Map<String, dynamic>)['index'] as num).toInt(),
              name: f['name'] as String? ?? '',
              size: (f['size'] as num?)?.toInt() ?? 0,
            ),
        ],
      ),
  ];
}
/// Doporučené na Domů mluveného slova -- podcasty (výsledek ve tvaru
/// hledání) a knihy (vydání ze SkTorrentu), u každého krátké "proč".
typedef SpokenRecommendations = ({
  List<({PodcastSearchResult show, String reason})> podcasts,
  List<({SpokenRelease release, String reason})> books,
});

final spokenRecommendationsProvider = FutureProvider.autoDispose<SpokenRecommendations>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/recommendations');
  return (
    podcasts: [
      for (final p in json['podcasts'] as List<dynamic>? ?? const [])
        if ((p as Map<String, dynamic>)['feedUrl'] != null)
          (show: PodcastSearchResult.fromJson(p), reason: p['reason'] as String? ?? ''),
    ],
    books: [
      for (final b in json['books'] as List<dynamic>? ?? const [])
        (release: SpokenRelease.fromJson(b as Map<String, dynamic>), reason: (b['reason'] as String?) ?? ''),
    ],
  );
});
