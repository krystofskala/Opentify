import 'artist_model.dart';
import 'recording_model.dart';

/// 1:1 s backend `YearInReviewOut` (`app/recommendations/schemas.py`) --
/// `GET /recommendations/year-in-review`. `range` je vždy `"year"` (LB
/// posledních 12 měsíců, ne přesně kalendářní rok) -- necháváme ho projít
/// z backendu, ať appka nikdy neslibuje přesnost, kterou zdroj dat nemá.
class YearInReviewModel {
  const YearInReviewModel({
    required this.range,
    required this.totalListens,
    required this.topTracks,
    required this.topArtists,
  });

  final String range;
  final int totalListens;
  final List<RecordingModel> topTracks;
  final List<ArtistModel> topArtists;

  bool get isEmpty => totalListens == 0 && topTracks.isEmpty && topArtists.isEmpty;

  factory YearInReviewModel.fromJson(Map<String, dynamic> json) => YearInReviewModel(
        range: json['range'] as String,
        totalListens: json['totalListens'] as int,
        topTracks: (json['topTracks'] as List<dynamic>? ?? const [])
            .map((e) => RecordingModel.fromJson(e as Map<String, dynamic>))
            .toList(),
        topArtists: (json['topArtists'] as List<dynamic>? ?? const [])
            .map((e) => ArtistModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
