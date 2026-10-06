import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/device_token.dart' show withDeviceToken;
import '../../core/realtime_event.dart' show UnknownEvent;
import '../../state/audio_player_controller.dart' show NowPlayingInfo;
import '../../state/providers.dart';

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
      );

  final String infohash;
  final String title;
  final int? sizeBytes;
  final int seeders;
  final String? coverUrl;
  final String? added;
  final String? bookId;
  final String? status;

  /// sktorrent (česky) | slskd (Soulseek, typicky anglicky).
  final String source;
  final String? ref;
  final int? files;
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

  bool get isReady => status == 'ready';
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
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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

final spokenBookProvider = FutureProvider.autoDispose.family<SpokenBook, String>((ref, id) async {
  ref.watch(spokenEventsProvider);
  return SpokenBook.fromJson(await ref.watch(apiClientProvider).getJson('/spoken/books/$id'));
});

typedef SpokenSearchResult = ({List<SpokenRelease> releases, bool loginConfigured});

final spokenSearchProvider = FutureProvider.autoDispose.family<SpokenSearchResult, String>((ref, q) async {
  ref.watch(spokenEventsProvider);
  final json = await ref.watch(apiClientProvider).getJson('/spoken/search', query: {'q': q});
  return (
    releases: [for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>)],
    loginConfigured: json['loginConfigured'] as bool? ?? false,
  );
});

/// Počítadlo událostí `spoken.book` z WS (stav stahování knihy).
final spokenEventsProvider = StreamProvider.autoDispose<int>((ref) async* {
  var n = 0;
  yield n;
  await for (final e in ref.watch(realtimeClientProvider).events) {
    if (e is UnknownEvent && e.type == 'spoken.book') yield ++n;
  }
});

Future<void> acquireSpoken(WidgetRef ref, SpokenRelease r, {List<int>? files, String? folder}) async {
  await ref.read(apiClientProvider).postJson('/spoken/books', body: {
    if (files != null) 'files': files,
    if (folder != null && folder.isNotEmpty) 'folder': folder,
    'source': r.source,
    if (r.ref != null) 'ref': r.ref,
    if (r.infohash.isNotEmpty) 'infohash': r.infohash,
    'title': r.title,
    'sizeBytes': r.sizeBytes,
  });
  ref.invalidate(spokenBooksProvider);
  ref.invalidate(spokenSearchProvider);
  ref.invalidate(spokenForeignSearchProvider);
}

/// Záloha za českou verzi: Soulseek (typicky anglické originály) -- zvlášť,
/// je pomalejší (~10 s).
final spokenForeignSearchProvider = FutureProvider.autoDispose.family<List<SpokenRelease>, String>((ref, q) async {
  ref.watch(spokenEventsProvider);
  final json = await ref.watch(apiClientProvider).getJson('/spoken/search/foreign', query: {'q': q});
  return [for (final r in json['releases'] as List<dynamic>? ?? const []) SpokenRelease.fromJson(r as Map<String, dynamic>)];
});

/// Kniha (složka) ve sbírce a její zvukové soubory (kapitoly).
typedef ReleaseFile = ({int index, String name, int size});
typedef ReleaseGroup = ({String folder, int size, List<ReleaseFile> files});

/// Obsah vydání před stažením (sbírka -> knihy). Chce účet SkTorrent.
Future<List<ReleaseGroup>> fetchReleaseGroups(WidgetRef ref, String infohash) async {
  final json = await ref.read(apiClientProvider).getJson('/spoken/releases/$infohash/files');
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