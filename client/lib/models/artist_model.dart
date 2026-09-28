import '../core/media_url.dart';

/// 1:1 s `components.schemas.Artist` v docs/openapi.yaml.
class ArtistModel {
  const ArtistModel({
    required this.id,
    this.mbid,
    this.deezerId,
    required this.name,
    this.sortName,
    this.images = const [],
  });

  final String id;
  final String? mbid;
  final String? deezerId;
  final String name;
  final String? sortName;
  final List<String> images;

  String? get coverImageUrl => images.isEmpty ? null : images.first;

  factory ArtistModel.fromJson(Map<String, dynamic> json) => ArtistModel(
        id: json['id'] as String,
        mbid: json['mbid'] as String?,
        deezerId: json['deezerId'] as String?,
        name: json['name'] as String,
        sortName: json['sortName'] as String?,
        images: resolveMediaUrls((json['images'] as List<dynamic>? ?? const []).cast<String>()),
      );
}
