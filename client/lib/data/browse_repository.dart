import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/media_url.dart';
import '../models/recording_model.dart';
import 'home_repository.dart';

/// Dlaždice stránky Procházet (nálada nebo žánr), viz backend app/browse.py.
class BrowseCategory {
  const BrowseCategory({required this.id, required this.title, required this.group, required this.color, this.icon});

  final String id;
  final String title;
  final String group; // mood | genre
  final Color color;
  final String? icon;

  factory BrowseCategory.fromJson(Map<String, dynamic> json) => BrowseCategory(
        id: json['id'] as String,
        title: json['title'] as String,
        group: json['group'] as String,
        color: _hex(json['color'] as String?),
        icon: json['icon'] as String?,
      );
}

Color _hex(String? hex) {
  final h = (hex ?? '#555555').replaceFirst('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

/// Playlist z Deezeru v kategorii -- do katalogu se převezme až při otevření.
class BrowsePlaylist {
  const BrowsePlaylist({
    required this.deezerId,
    required this.title,
    this.pictureUrl,
    this.trackCount,
    required this.editorial,
  });

  final String deezerId;
  final String title;
  final String? pictureUrl;
  final int? trackCount;
  final bool editorial;

  factory BrowsePlaylist.fromJson(Map<String, dynamic> json) => BrowsePlaylist(
        deezerId: json['deezerId'] as String,
        title: json['title'] as String,
        pictureUrl: json['pictureUrl'] as String?,
        trackCount: json['trackCount'] as int?,
        editorial: json['editorial'] as bool? ?? false,
      );
}

class BrowseArtist {
  const BrowseArtist({required this.id, required this.name, this.images = const []});

  final String id;
  final String name;
  final List<String> images;

  factory BrowseArtist.fromJson(Map<String, dynamic> json) => BrowseArtist(
        id: json['id'] as String,
        name: json['name'] as String,
        images: resolveMediaUrls((json['images'] as List<dynamic>? ?? const []).cast<String>()),
      );
}

class BrowsePage {
  const BrowsePage({
    required this.category,
    this.playlists = const [],
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final BrowseCategory category;
  final List<BrowsePlaylist> playlists;
  final List<RecordingModel> tracks;
  final List<HomeAlbumCard> albums;
  final List<BrowseArtist> artists;

  factory BrowsePage.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> list(String key) =>
        (json[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    return BrowsePage(
      category: BrowseCategory.fromJson(json),
      playlists: list('playlists').map(BrowsePlaylist.fromJson).toList(),
      tracks: list('tracks').map(RecordingModel.fromJson).toList(),
      albums: list('albums').map(HomeAlbumCard.fromJson).toList(),
      artists: list('artists').map(BrowseArtist.fromJson).toList(),
    );
  }
}

class BrowseRepository {
  BrowseRepository(this._api);

  final ApiClient _api;

  Future<List<BrowseCategory>> categories() async {
    final json = await _api.getJson('/browse');
    return (json['categories'] as List<dynamic>).cast<Map<String, dynamic>>().map(BrowseCategory.fromJson).toList();
  }

  Future<BrowsePage> page(String categoryId) async => BrowsePage.fromJson(await _api.getJson('/browse/$categoryId'));

  /// Převezme Deezer playlist do katalogu a vrátí id našeho playlistu.
  Future<String> openDeezerPlaylist(String deezerId) async {
    final json = await _api.postJson('/browse/deezer-playlists/$deezerId');
    return json['playlistId'] as String;
  }
}
