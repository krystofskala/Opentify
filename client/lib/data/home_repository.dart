import '../core/api_client.dart';
import '../core/media_url.dart';
import '../models/recording_model.dart';
import 'browse_repository.dart' show BrowseCategory;

/// Karta playlistu na Domů (žebříček, žánr, výběr, osobní mix).
class HomePlaylistCard {
  const HomePlaylistCard({
    required this.id,
    required this.title,
    required this.kind,
    required this.itemCount,
    this.description,
    this.source,
    this.section,
    this.coverUrls = const [],
    this.badge,
    this.accentColor,
    this.artStyle,
  });

  /// Generativní obal vlastního mixu: daily | genre | mood | year.
  final String? artStyle;

  final String id;
  final String title;
  final String kind; // CHART | GENRE | EDITORIAL | GENERATED_RECOMMENDATION | PERSONAL_MIX | USER
  final int itemCount;
  final String? description;
  final String? source;
  final String? section;
  final List<String> coverUrls;
  final String? badge;

  /// Barva kategorie u "Tvůj mix · X" (`#RRGGBB`).
  final String? accentColor;

  /// "Rock" z "Tvůj mix · Rock" -- mix kategorie Procházet má vlastní obal.
  String? get categoryMixLabel {
    if (!(source ?? '').startsWith('personal:category-mix:')) return null;
    final i = title.indexOf('· ');
    return i < 0 ? title : title.substring(i + 2);
  }

  /// Žánry a nálady bez skutečné mozaiky dostanou tónovaný zrnitý gradient.
  bool get prefersGradient => kind == 'GENRE';

  /// Číslo "Denního mixu" (`personal:daily-mix:N`) -- ty mají vlastní obal
  /// (tónovaný gradient s číslem a fotkami interpretů), ne mozaiku alb.
  int? get dailyMixNumber {
    const prefix = 'personal:daily-mix:';
    final s = source;
    if (s == null || !s.startsWith(prefix)) return null;
    return int.tryParse(s.substring(prefix.length));
  }

  factory HomePlaylistCard.fromJson(Map<String, dynamic> json) => HomePlaylistCard(
        id: json['id'] as String,
        title: json['title'] as String,
        kind: json['kind'] as String,
        itemCount: json['itemCount'] as int? ?? 0,
        description: json['description'] as String?,
        source: json['source'] as String?,
        section: json['section'] as String?,
        coverUrls: resolveMediaUrls((json['coverUrls'] as List<dynamic>? ?? const []).cast<String>()),
        badge: json['badge'] as String?,
        accentColor: json['accentColor'] as String?,
        artStyle: json['artStyle'] as String?,
      );
}

/// Karta alba na Domů (nová vydání, populární alba).
class HomeAlbumCard {
  const HomeAlbumCard({
    required this.id,
    required this.title,
    required this.artistId,
    this.artistName,
    this.releaseDate,
    this.images = const [],
  });

  final String id;
  final String title;
  final String artistId;
  final String? artistName;
  final String? releaseDate;
  final List<String> images;

  factory HomeAlbumCard.fromJson(Map<String, dynamic> json) => HomeAlbumCard(
        id: json['id'] as String,
        title: json['title'] as String,
        artistId: json['artistId'] as String,
        artistName: json['artistName'] as String?,
        releaseDate: json['releaseDate'] as String?,
        images: resolveMediaUrls((json['images'] as List<dynamic>? ?? const []).cast<String>()),
      );
}

enum HomeSectionType { quickPicks, playlistCards, albumCards, trackRail, categoryTiles, unknown }

HomeSectionType _typeFrom(String? raw) => switch (raw) {
      'quick_picks' => HomeSectionType.quickPicks,
      'playlist_cards' => HomeSectionType.playlistCards,
      'album_cards' => HomeSectionType.albumCards,
      'track_rail' => HomeSectionType.trackRail,
      'category_tiles' => HomeSectionType.categoryTiles,
      _ => HomeSectionType.unknown,
    };

/// Jedna sekce `GET /home` -- podle `type` nese jeden ze seznamů.
class HomeSection {
  const HomeSection({
    required this.id,
    required this.title,
    required this.type,
    this.playlists = const [],
    this.albums = const [],
    this.tracks = const [],
    this.categories = const [],
    this.playlistId,
  });

  final String id;
  final String title;
  final HomeSectionType type;
  final List<HomePlaylistCard> playlists;
  final List<HomeAlbumCard> albums;
  final List<RecordingModel> tracks;

  /// Dlaždice žánrů -- stejné jako v Hledat (`BrowseTile`).
  final List<BrowseCategory> categories;

  /// Track rail z playlistu (např. Top Worldwide) -- "Zobrazit vše" ho otevře.
  final String? playlistId;

  factory HomeSection.fromJson(Map<String, dynamic> json) {
    final type = _typeFrom(json['type'] as String?);
    final items = (json['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    return HomeSection(
      id: json['id'] as String,
      title: json['title'] as String,
      type: type,
      playlistId: json['playlistId'] as String?,
      playlists: type == HomeSectionType.playlistCards || type == HomeSectionType.quickPicks
          ? items.map(HomePlaylistCard.fromJson).toList()
          : const [],
      albums: type == HomeSectionType.albumCards ? items.map(HomeAlbumCard.fromJson).toList() : const [],
      tracks: type == HomeSectionType.trackRail ? items.map(RecordingModel.fromJson).toList() : const [],
      categories: type == HomeSectionType.categoryTiles ? items.map(BrowseCategory.fromJson).toList() : const [],
    );
  }
}

/// Položka "Pokračovat v poslechu" (`GET /home/recent`) -- album, nebo
/// skladba bez alba.
class RecentContext {
  const RecentContext({
    required this.kind,
    required this.id,
    required this.title,
    this.artistName,
    this.artistId,
    this.imageUrl,
    this.imageUrls = const [],
    this.source,
    this.accentColor,
    this.artStyle,
  });

  final String kind; // album | track | playlist | liked | artist
  final String id;
  final String title;
  final String? artistName;
  final String? artistId;
  final String? imageUrl;

  /// Mozaika playlistu (až 4 obaly).
  final List<String> imageUrls;

  /// `Playlist.source` -- podle něj Denní mix dostane svůj obal.
  final String? source;

  /// Barva a styl generativního obalu (mixy kategorií) -- jako na kartě Domů.
  final String? accentColor;
  final String? artStyle;

  int? get dailyMixNumber {
    const prefix = 'personal:daily-mix:';
    final s = source;
    if (s == null || !s.startsWith(prefix)) return null;
    return int.tryParse(s.substring(prefix.length));
  }

  factory RecentContext.fromJson(Map<String, dynamic> json) => RecentContext(
        kind: json['kind'] as String,
        id: json['id'] as String,
        title: json['title'] as String,
        artistName: json['artistName'] as String?,
        artistId: json['artistId'] as String?,
        imageUrl: resolveMediaUrl(json['imageUrl'] as String?),
        imageUrls: resolveMediaUrls((json['imageUrls'] as List<dynamic>? ?? const []).cast<String>()),
        source: json['source'] as String?,
        accentColor: json['accentColor'] as String?,
        artStyle: json['artStyle'] as String?,
      );
}

class HomeRepository {
  HomeRepository(this._api);

  final ApiClient _api;

  Future<List<RecentContext>> recent() async {
    final json = await _api.getJsonList('/home/recent');
    return json.map((e) => RecentContext.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<HomeSection>> home() async {
    final json = await _api.getJson('/home');
    return (json['sections'] as List<dynamic>? ?? const [])
        .map((e) => HomeSection.fromJson(e as Map<String, dynamic>))
        .where((s) => s.type != HomeSectionType.unknown)
        .toList();
  }
}
