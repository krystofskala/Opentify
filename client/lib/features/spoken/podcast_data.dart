import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/audio_player_controller.dart' show NowPlayingInfo;
import '../../state/providers.dart';

/// Podcasty (backend app/routes/podcasts.py) -- odděleně od hudby.

/// Audioknihy, nebo podcasty -- přepínač v Hledání a Knihovně mluveného slova.
enum SpokenKind { books, podcasts }

final spokenKindProvider = StateProvider<SpokenKind>((ref) => SpokenKind.books);

class PodcastSearchResult {
  const PodcastSearchResult({
    required this.title,
    required this.feedUrl,
    this.author,
    this.artworkUrl,
    this.itunesId,
    this.subscribed = false,
  });

  factory PodcastSearchResult.fromJson(Map<String, dynamic> j) => PodcastSearchResult(
        title: j['title'] as String? ?? '',
        feedUrl: j['feedUrl'] as String,
        author: j['author'] as String?,
        artworkUrl: j['artworkUrl'] as String?,
        itunesId: j['itunesId'] as String?,
        subscribed: j['subscribed'] as bool? ?? false,
      );

  final String title;
  final String feedUrl;
  final String? author;
  final String? artworkUrl;
  final String? itunesId;
  final bool subscribed;
}

class PodcastEpisodeItem {
  const PodcastEpisodeItem({
    required this.id,
    required this.title,
    this.showTitle,
    this.description,
    this.publishedAt,
    this.durationMs,
    this.artworkUrl,
    this.positionMs = 0,
    this.finished = false,
  });

  factory PodcastEpisodeItem.fromJson(Map<String, dynamic> j) => PodcastEpisodeItem(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        showTitle: j['showTitle'] as String?,
        description: j['description'] as String?,
        publishedAt: j['publishedAt'] == null ? null : DateTime.tryParse(j['publishedAt'] as String)?.toLocal(),
        durationMs: (j['durationMs'] as num?)?.toInt(),
        artworkUrl: j['artworkUrl'] as String?,
        positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
        finished: j['finished'] as bool? ?? false,
      );

  final String id;
  final String title;
  final String? showTitle;
  final String? description;
  final DateTime? publishedAt;
  final int? durationMs;
  final String? artworkUrl;
  final int positionMs;
  final bool finished;

  bool get started => positionMs > 0 && !finished;

  NowPlayingInfo toQueueItem() => NowPlayingInfo(
        recordingId: 'pc:$id',
        title: title,
        artistName: showTitle,
        artworkUrl: artworkUrl,
      );
}

class PodcastShowItem {
  const PodcastShowItem({
    required this.id,
    required this.title,
    this.author,
    this.description,
    this.artworkUrl,
    this.subscribed = false,
    this.episodes = const [],
  });

  factory PodcastShowItem.fromJson(Map<String, dynamic> j) => PodcastShowItem(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        author: j['author'] as String?,
        description: j['description'] as String?,
        artworkUrl: j['artworkUrl'] as String?,
        subscribed: j['subscribed'] as bool? ?? false,
        episodes: [
          for (final e in j['episodes'] as List<dynamic>? ?? const [])
            PodcastEpisodeItem.fromJson(e as Map<String, dynamic>),
        ],
      );

  final String id;
  final String title;
  final String? author;
  final String? description;
  final String? artworkUrl;
  final bool subscribed;
  final List<PodcastEpisodeItem> episodes;
}

final podcastSearchProvider = FutureProvider.autoDispose.family<List<PodcastSearchResult>, String>((ref, q) async {
  final json = await ref.watch(apiClientProvider).getJson('/podcasts/search', query: {'q': q});
  return [for (final s in json['shows'] as List<dynamic>? ?? const []) PodcastSearchResult.fromJson(s as Map<String, dynamic>)];
});

final myPodcastsProvider = FutureProvider.autoDispose<List<PodcastShowItem>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/podcasts/shows');
  return [for (final s in json['shows'] as List<dynamic>? ?? const []) PodcastShowItem.fromJson(s as Map<String, dynamic>)];
});

final podcastShowProvider = FutureProvider.autoDispose.family<PodcastShowItem, String>((ref, id) async {
  return PodcastShowItem.fromJson(await ref.watch(apiClientProvider).getJson('/podcasts/shows/$id'));
});

typedef PodcastHome = ({List<PodcastEpisodeItem> inProgress, List<PodcastEpisodeItem> latest});

final podcastHomeProvider = FutureProvider.autoDispose<PodcastHome>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/podcasts/new', query: {'limit': '15'});
  List<PodcastEpisodeItem> list(String key) => [
        for (final e in json[key] as List<dynamic>? ?? const []) PodcastEpisodeItem.fromJson(e as Map<String, dynamic>),
      ];
  return (inProgress: list('inProgress'), latest: list('episodes'));
});

/// Pořad z importované historie (Spotify) -- nabídka k odběru.
class PodcastHistoryItem {
  const PodcastHistoryItem({
    required this.name,
    required this.title,
    required this.listenedMs,
    required this.episodes,
    this.lastPlayedAt,
    required this.pending,
    required this.found,
    this.feedUrl,
    this.author,
    this.artworkUrl,
    this.itunesId,
    this.showId,
    required this.subscribed,
  });

  factory PodcastHistoryItem.fromJson(Map<String, dynamic> j) => PodcastHistoryItem(
        name: j['name'] as String,
        title: j['title'] as String? ?? j['name'] as String,
        listenedMs: (j['listenedMs'] as num?)?.toInt() ?? 0,
        episodes: (j['episodes'] as num?)?.toInt() ?? 0,
        lastPlayedAt: j['lastPlayedAt'] == null ? null : DateTime.tryParse(j['lastPlayedAt'] as String)?.toLocal(),
        pending: j['pending'] as bool? ?? false,
        found: j['found'] as bool? ?? false,
        feedUrl: j['feedUrl'] as String?,
        author: j['author'] as String?,
        artworkUrl: j['artworkUrl'] as String?,
        itunesId: j['itunesId'] as String?,
        showId: j['showId'] as String?,
        subscribed: j['subscribed'] as bool? ?? false,
      );

  final String name;
  final String title;
  final int listenedMs;
  final int episodes;
  final DateTime? lastPlayedAt;
  final bool pending;
  final bool found;
  final String? feedUrl;
  final String? author;
  final String? artworkUrl;
  final String? itunesId;
  final String? showId;
  final bool subscribed;

  PodcastSearchResult? get asResult => feedUrl == null
      ? null
      : PodcastSearchResult(title: title, feedUrl: feedUrl!, author: author, artworkUrl: artworkUrl, itunesId: itunesId);
}

final podcastHistoryProvider = FutureProvider.autoDispose<List<PodcastHistoryItem>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/podcasts/history');
  return [for (final s in json['shows'] as List<dynamic>? ?? const []) PodcastHistoryItem.fromJson(s as Map<String, dynamic>)];
});

/// Odebírat pořad z historie: založit ho v DB a přihlásit odběr. Vrací,
/// kolik epizod se označilo jako přehrané podle historie.
Future<int> subscribeFromHistory(WidgetRef ref, PodcastHistoryItem item) async {
  final result = item.asResult;
  if (result == null) return 0;
  final id = item.showId ?? await openPodcast(ref, result);
  final json = await ref.read(apiClientProvider).putJson('/podcasts/shows/$id/subscription');
  ref.invalidate(podcastHistoryProvider);
  ref.invalidate(myPodcastsProvider);
  ref.invalidate(podcastHomeProvider);
  return (json['markedFromHistory'] as num?)?.toInt() ?? 0;
}

/// Id pořadu v naší DB pro výsledek hledání (načte RSS při otevření).
Future<String> openPodcast(WidgetRef ref, PodcastSearchResult r) async {
  final json = await ref.read(apiClientProvider).postJson('/podcasts/shows', body: {
    'feedUrl': r.feedUrl,
    'title': r.title,
    'author': r.author,
    'artworkUrl': r.artworkUrl,
    'itunesId': r.itunesId,
  });
  return json['id'] as String;
}

Future<void> setPodcastSubscribed(WidgetRef ref, String showId, bool on) async {
  final api = ref.read(apiClientProvider);
  if (on) {
    await api.putJson('/podcasts/shows/$showId/subscription');
  } else {
    await api.deleteJson('/podcasts/shows/$showId/subscription');
  }
  ref.invalidate(podcastShowProvider(showId));
  ref.invalidate(myPodcastsProvider);
  ref.invalidate(podcastHomeProvider);
  ref.invalidate(podcastSearchProvider);
}

const _months = ['led', 'úno', 'bře', 'dub', 'kvě', 'čvn', 'čvc', 'srp', 'zář', 'říj', 'lis', 'pro'];

String episodeDate(DateTime? d, DateTime now) {
  if (d == null) return '';
  final day = DateTime(d.year, d.month, d.day);
  final diff = DateTime(now.year, now.month, now.day).difference(day).inDays;
  if (diff == 0) return 'Dnes';
  if (diff == 1) return 'Včera';
  return d.year == now.year ? '${d.day}. ${_months[d.month - 1]}' : '${d.day}. ${_months[d.month - 1]} ${d.year}';
}
