import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/media_url.dart';

/// Období Wrappedu (rok nebo dekáda), viz backend app/wrapped.py.
class WrappedPeriod {
  const WrappedPeriod({required this.id, required this.label, required this.locked, this.partial = false});

  final String id;
  final String label;
  final bool locked;
  final bool partial;

  bool get isDecade => id == 'decade';
}

class WrappedIndex {
  const WrappedIndex({required this.decade, required this.years, required this.unlockAt});

  final WrappedPeriod decade;
  final List<WrappedPeriod> years;
  final DateTime unlockAt;

  factory WrappedIndex.fromJson(Map<String, dynamic> json) {
    final d = json['decade'] as Map<String, dynamic>;
    return WrappedIndex(
      decade: WrappedPeriod(id: 'decade', label: '${d['from']}–${d['to']}', locked: d['locked'] as bool),
      years: [
        for (final y in (json['years'] as List<dynamic>).cast<Map<String, dynamic>>())
          WrappedPeriod(
            id: y['id'] as String,
            label: y['id'] as String,
            locked: y['locked'] as bool,
            partial: y['partial'] as bool? ?? false,
          ),
      ],
      unlockAt: DateTime.parse(json['unlockAt'] as String),
    );
  }
}

class WrappedArtist {
  const WrappedArtist({required this.id, required this.name, this.imageUrl, this.minutes = 0, this.plays = 0});

  final String id;
  final String name;
  final String? imageUrl;
  final int minutes;
  final int plays;

  factory WrappedArtist.fromJson(Map<String, dynamic> j) => WrappedArtist(
        id: j['id'] as String,
        name: j['name'] as String? ?? '?',
        imageUrl: resolveMediaUrl(j['imageUrl'] as String?),
        minutes: j['minutes'] as int? ?? 0,
        plays: j['plays'] as int? ?? 0,
      );
}

class WrappedTrack {
  const WrappedTrack({
    required this.id,
    required this.title,
    this.artistId,
    this.artistName,
    this.releaseId,
    this.imageUrl,
    this.plays = 0,
    this.minutes = 0,
    this.years = 0,
  });

  final String id;
  final String title;
  final String? artistId;
  final String? artistName;
  final String? releaseId;
  final String? imageUrl;
  final int plays;
  final int minutes;

  /// Nesmrtelné: v kolika letech byla v top 100.
  final int years;

  factory WrappedTrack.fromJson(Map<String, dynamic> j) => WrappedTrack(
        id: j['id'] as String,
        title: j['title'] as String? ?? '?',
        artistId: j['artistId'] as String?,
        artistName: j['artistName'] as String?,
        releaseId: j['releaseId'] as String?,
        imageUrl: resolveMediaUrl(j['imageUrl'] as String?),
        plays: j['plays'] as int? ?? 0,
        minutes: j['minutes'] as int? ?? 0,
        years: j['years'] as int? ?? 0,
      );
}

class WrappedGenre {
  const WrappedGenre({required this.title, required this.color, required this.minutes, required this.percent});

  final String title;
  final Color color;
  final int minutes;
  final int percent;
}

class WrappedEra {
  const WrappedEra({required this.year, required this.artist, required this.track});

  final int year;
  final WrappedArtist artist;
  final WrappedTrack track;
}

class WrappedStats {
  const WrappedStats({
    required this.id,
    required this.label,
    this.locked = false,
    this.partial = false,
    this.totalMinutes = 0,
    this.plays = 0,
    this.daysListened = 0,
    this.artistsCount = 0,
    this.tracksCount = 0,
    this.topArtists = const [],
    this.topTracks = const [],
    this.topGenres = const [],
    this.newArtists = 0,
    this.topNewArtist,
    this.peakHour = 0,
    this.hours = const [],
    this.timeline = const [],
    this.eras = const [],
    this.evergreens = const [],
    this.playlists = const [],
    this.unlockAt,
  });

  final String id;
  final String label;
  final bool locked;
  final bool partial;
  final int totalMinutes;
  final int plays;
  final int daysListened;
  final int artistsCount;
  final int tracksCount;
  final List<WrappedArtist> topArtists;
  final List<WrappedTrack> topTracks;
  final List<WrappedGenre> topGenres;
  final int newArtists;
  final WrappedArtist? topNewArtist;
  final int peakHour;
  final List<int> hours;

  /// Rok: minuty po měsících (key 1–12); dekáda: po letech.
  final List<({int key, int minutes})> timeline;
  final List<WrappedEra> eras;
  final List<WrappedTrack> evergreens;
  final List<({String id, String title})> playlists;
  final DateTime? unlockAt;

  bool get isDecade => id == 'decade';

  factory WrappedStats.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> list(String key) => (j[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    Color hex(String? h) => Color(int.tryParse('FF${(h ?? '#6A5ACD').replaceFirst('#', '')}', radix: 16) ?? 0xFF6A5ACD);
    final id = j['id'] as String;
    return WrappedStats(
      id: id,
      label: j['label'] as String? ?? id,
      locked: j['locked'] as bool? ?? false,
      partial: j['partial'] as bool? ?? false,
      totalMinutes: j['totalMinutes'] as int? ?? 0,
      plays: j['plays'] as int? ?? 0,
      daysListened: j['daysListened'] as int? ?? 0,
      artistsCount: j['artistsCount'] as int? ?? 0,
      tracksCount: j['tracksCount'] as int? ?? 0,
      topArtists: list('topArtists').map(WrappedArtist.fromJson).toList(),
      topTracks: list('topTracks').map(WrappedTrack.fromJson).toList(),
      topGenres: [
        for (final g in list('topGenres'))
          WrappedGenre(
            title: g['title'] as String,
            color: hex(g['color'] as String?),
            minutes: g['minutes'] as int? ?? 0,
            percent: g['percent'] as int? ?? 0,
          ),
      ],
      newArtists: j['newArtists'] as int? ?? 0,
      topNewArtist:
          j['topNewArtist'] == null ? null : WrappedArtist.fromJson(j['topNewArtist'] as Map<String, dynamic>),
      peakHour: j['peakHour'] as int? ?? 0,
      hours: (j['hours'] as List<dynamic>? ?? const []).cast<int>(),
      timeline: [for (final t in list('timeline')) (key: t['key'] as int, minutes: t['minutes'] as int? ?? 0)],
      eras: [
        for (final e in list('eras'))
          WrappedEra(
            year: e['year'] as int,
            artist: WrappedArtist.fromJson(e['artist'] as Map<String, dynamic>),
            track: WrappedTrack.fromJson(e['track'] as Map<String, dynamic>),
          ),
      ],
      evergreens: list('evergreens').map(WrappedTrack.fromJson).toList(),
      playlists: [for (final p in list('playlists')) (id: p['id'] as String, title: p['title'] as String)],
      unlockAt: j['unlockAt'] == null ? null : DateTime.parse(j['unlockAt'] as String),
    );
  }
}

class WrappedRepository {
  WrappedRepository(this._api);

  final ApiClient _api;

  Future<WrappedIndex> index() async => WrappedIndex.fromJson(await _api.getJson('/wrapped'));

  /// První výpočet roku může trvat ~10 s (zařazování interpretů do žánrů);
  /// server ho pak drží v cache.
  Future<WrappedStats> stats(String period) async => WrappedStats.fromJson(await _api.getJson('/wrapped/$period'));
}
