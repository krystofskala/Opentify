import '../core/media_url.dart';

/// 1:1 s `components.schemas.Release` v docs/openapi.yaml.
class ReleaseModel {
  const ReleaseModel({
    required this.id,
    this.mbid,
    required this.artistId,
    required this.title,
    this.releaseDate,
    required this.releaseType,
    this.images = const [],
    this.notes,
  });

  final String id;
  final String? mbid;
  final String artistId;
  final String title;
  final String? releaseDate; // ISO řetězec, může být jen rok ("1997") — viz backend Release.release_date
  final String releaseType; // album | ep | single | compilation
  final List<String> images;

  /// Vlastní poznámka k albu (obsazení apod.), jen u vlastní hudby.
  final String? notes;

  String? get coverImageUrl => images.isEmpty ? null : images.first;

  /// MusicBrainz `first-release-date` bývá jen rok nebo rok-měsíc — zobrazí
  /// se, co backend poslal, žádné falšování na plné datum.
  String get yearLabel => (releaseDate == null || releaseDate!.length < 4)
      ? '—'
      : releaseDate!.substring(0, 4);

  factory ReleaseModel.fromJson(Map<String, dynamic> json) => ReleaseModel(
        id: json['id'] as String,
        mbid: json['mbid'] as String?,
        artistId: json['artistId'] as String,
        title: json['title'] as String,
        releaseDate: json['releaseDate'] as String?,
        releaseType: json['releaseType'] as String? ?? 'album',
        images: resolveMediaUrls((json['images'] as List<dynamic>? ?? const []).cast<String>()),
        notes: json['notes'] as String?,
      );
}
