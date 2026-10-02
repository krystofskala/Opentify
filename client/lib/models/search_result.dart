import '../core/media_url.dart';
import 'availability.dart';
import 'recording_model.dart';

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
    this.artistId,
    this.artistName,
    this.releaseId,
    this.durationMs,
  });

  final SearchEntityType entityType;
  final String id;
  final String title;
  final String? subtitle;

  /// Jen pro `recording` — artist/release mají binární "existuje v katalogu",
  /// ne třístavovou dostupnost média.
  final Availability? availability;
  final String? imageUrl;

  /// Jen pro `recording` — `RecordingOut` je nese (viz backend
  /// `app/catalog/schemas.py`), ale samo `imageUrl` nemá (žádné pole v
  /// `Recording` schématu, viz docs/openapi.yaml). Použij je jako klíč do
  /// `recordingArtworkProvider`, když chceš pro řádek reálný obal/foto
  /// interpreta místo placeholderu.
  final String? artistId;

  /// Jen pro `recording` -- denormalizované jméno interpreta z
  /// `RecordingOut.artist_name` (backend `app/catalog/schemas.py`), použité
  /// jako `subtitle` a předané dál do `NowPlayingInfo` při přehrání.
  final String? artistName;
  final String? releaseId;
  final int? durationMs;

  /// Nahrávka z výsledku hledání jako běžný `RecordingModel` -- ať se ve
  /// výsledcích vykresluje stejným `TrackTile` jako kdekoliv jinde v appce
  /// (interpret, proklik, srdíčko, kontextové menu).
  RecordingModel toRecordingModel() => RecordingModel(
        id: id,
        releaseId: releaseId,
        artistId: artistId,
        artistName: artistName,
        title: title,
        durationMs: durationMs,
        availability: availability ?? Availability.provisionable,
      );

  factory SearchResultItem.fromJson(Map<String, dynamic> json) {
    final rawType = json['entityType'] as String;
    switch (rawType) {
      case 'artist':
        final images = resolveMediaUrls((json['images'] as List<dynamic>? ?? const []).cast<String>());
        return SearchResultItem(
          entityType: SearchEntityType.artist,
          id: json['id'] as String,
          title: json['name'] as String,
          subtitle: 'Interpret',
          artistId: json['id'] as String,
          imageUrl: images.isEmpty ? null : images.first,
        );
      case 'release':
        final images = resolveMediaUrls((json['images'] as List<dynamic>? ?? const []).cast<String>());
        final year = (json['releaseDate'] as String?);
        return SearchResultItem(
          entityType: SearchEntityType.release,
          id: json['id'] as String,
          title: json['title'] as String,
          artistId: json['artistId'] as String?,
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
          subtitle: (json['artistName'] as String?) ?? 'Skladba',
          availability: availabilityFromJson(json['availability'] as String?),
          artistId: json['artistId'] as String?,
          artistName: json['artistName'] as String?,
          releaseId: json['releaseId'] as String?,
          durationMs: json['durationMs'] as int?,
        );
      default:
        throw FormatException('Neznámý entityType v /catalog/search: $rawType');
    }
  }
}

class CatalogSearchResult {
  const CatalogSearchResult({required this.query, required this.total, required this.results, this.didYouMean});

  final String query;

  /// Opravený dotaz (Last.fm), když se původní skoro nic nenašlo.
  final String? didYouMean;
  final int total;
  final List<SearchResultItem> results;

  factory CatalogSearchResult.fromJson(Map<String, dynamic> json) => CatalogSearchResult(
        query: json['query'] as String,
        total: json['total'] as int,
        didYouMean: json['didYouMean'] as String?,
        results: (json['results'] as List<dynamic>)
            .map((e) => SearchResultItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
