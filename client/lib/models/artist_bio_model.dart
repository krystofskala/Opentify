import 'artist_model.dart';

/// 1:1 s backend `ArtistBioOut` (`app/catalog/schemas.py`) --
/// `GET /catalog/artists/{id}/bio`. Odděleně od `ArtistModel`, ne jako jeho
/// pole -- životopis/podobní interpreti chodí z Wikidata/Wikipedie
/// (best-effort, pomalejší než čistě lokální MusicBrainz data), takže
/// `ArtistScreen` je natahuje samostatným, později doběhnuvším requestem.
class ArtistBioModel {
  const ArtistBioModel({this.bio, this.relatedArtists = const [], this.bands = const [], this.members = const []});

  final String? bio;
  final List<ArtistModel> relatedArtists;

  /// Člověk: kapely a projekty, ve kterých hraje/hrál.
  final List<ArtistModel> bands;

  /// Kapela: členové (současní napřed).
  final List<ArtistModel> members;

  static List<ArtistModel> _list(Object? raw) =>
      (raw as List<dynamic>? ?? const []).map((e) => ArtistModel.fromJson(e as Map<String, dynamic>)).toList();

  factory ArtistBioModel.fromJson(Map<String, dynamic> json) => ArtistBioModel(
        bio: json['bio'] as String?,
        relatedArtists: _list(json['relatedArtists']),
        bands: _list(json['bands']),
        members: _list(json['members']),
      );
}
