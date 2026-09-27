import 'availability.dart';

enum SearchEntityType { artist, release, recording }

/// `GET /catalog/search` vrací zploštělou položku podle `entityType`
/// (`oneOf` Artist/Release/Recording v docs/openapi.yaml). Klient tu union
/// mapuje na jeden zobrazitelný tvar (title/subtitle/image/availability),
/// aby výsledkový list mohl renderovat všechny tři typy jedním widgetem
/// (viz features/search/search_screen.dart) a klikem routovat podle
/// `entityType` na správnou obrazovku.
class SearchResultItem {
  const SearchResultItem({
    required this.entityType,
    required this.id,
    required this.title,
    this.subtitle,
    this.availability,
    this.imageUrl,
  });

  final SearchEntityType entityType;
  final String id;
  final String title;
  final String? subtitle;

  /// Jen pro `recording` — artist/release mají binární "existuje v katalogu",
  /// ne třístavovou dostupnost média.
  final Availability? availability;
  final String? imageUrl;

  factory SearchResultItem.fromJson(Map<String, dynamic> json) {
    final rawType = json['entityType'] as String;
    switch (rawType) {
      case 'artist':
        final images = (json['images'] as List<dynamic>? ?? const []).cast<String>();
        return SearchResultItem(
          entityType: SearchEntityType.artist,
          id: json['id'] as String,
          title: json['name'] as String,
          subtitle: 'Interpret',
          imageUrl: images.isEmpty ? null : images.first,
        );
      case 'release':
        final images = (json['images'] as List<dynamic>? ?? const []).cast<String>();
        final year = (json['releaseDate'] as String?);
        return SearchResultItem(
          entityType: SearchEntityType.release,
          id: json['id'] as String,
          title: json['title'] as String,
          subtitle: [
            (json['releaseType'] as String?) ?? 'album',
            if (year != null && year.length >= 4) year.substring(0, 4),
          ].join(' · '),
          imageUrl: images.isEmpty ? null : images.first,
        );
      case 'recording':
        return SearchResultItem(
          entityType: SearchEntityType.recording,
          id: json['id'] as String,
          title: json['title'] as String,
          subtitle: 'Skladba',
          availability: availabilityFromJson(json['availability'] as String?),
        );
      default:
        throw FormatException('Neznámý entityType v /catalog/search: $rawType');
    }
  }
}

class CatalogSearchResult {
  const CatalogSearchResult({required this.query, required this.total, required this.results});

  final String query;
  final int total;
  final List<SearchResultItem> results;

  factory CatalogSearchResult.fromJson(Map<String, dynamic> json) => CatalogSearchResult(
        query: json['query'] as String,
        total: json['total'] as int,
        results: (json['results'] as List<dynamic>)
            .map((e) => SearchResultItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
