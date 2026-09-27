import 'artist_model.dart';
import 'release_model.dart';

/// 1:1 s response tvarem `GET /catalog/artists/{id}/discography`.
class DiscographyModel {
  const DiscographyModel({required this.artist, required this.releases});

  final ArtistModel artist;
  final List<ReleaseModel> releases;

  /// Alba rozdělená podle `releaseType`, v pořadí album/ep/single/compilation
  /// a uvnitř každé skupiny od nejnovějšího — přesně jak to obrazovka
  /// interpreta (features/artist/artist_screen.dart) chce renderovat.
  Map<String, List<ReleaseModel>> get groupedByType {
    const order = ['album', 'ep', 'single', 'compilation'];
    final grouped = <String, List<ReleaseModel>>{};
    for (final type in order) {
      final matching = releases.where((r) => r.releaseType == type).toList()
        ..sort((a, b) => (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''));
      if (matching.isNotEmpty) grouped[type] = matching;
    }
    return grouped;
  }

  factory DiscographyModel.fromJson(Map<String, dynamic> json) => DiscographyModel(
        artist: ArtistModel.fromJson(json['artist'] as Map<String, dynamic>),
        releases: (json['releases'] as List<dynamic>)
            .map((e) => ReleaseModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
