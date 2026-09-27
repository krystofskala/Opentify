import 'recording_model.dart';

/// 1:1 s `components.schemas.Playlist`/`PlaylistDetail` v docs/openapi.yaml.
/// `PlaylistDetailModel` je to, co vrací `GET /recommendations/daily-jams`
/// i budoucí `GET /playlists/{id}` — stejný tvar pro doporučené i uživatelské
/// playlisty, aby je HomeScreen mohl renderovat identickým widgetem.
class PlaylistDetailModel {
  const PlaylistDetailModel({
    required this.id,
    required this.title,
    required this.kind,
    this.source,
    this.generatedAt,
    required this.itemCount,
    required this.items,
  });

  final String id;
  final String title;
  final String kind; // USER | GENERATED_RECOMMENDATION | RADIO
  final String? source;
  final DateTime? generatedAt;
  final int itemCount;
  final List<RecordingModel> items;

  factory PlaylistDetailModel.fromJson(Map<String, dynamic> json) => PlaylistDetailModel(
        id: json['id'] as String,
        title: json['title'] as String,
        kind: json['kind'] as String,
        source: json['source'] as String?,
        generatedAt:
            json['generatedAt'] == null ? null : DateTime.parse(json['generatedAt'] as String),
        itemCount: json['itemCount'] as int,
        items: (json['items'] as List<dynamic>)
            .map((e) => RecordingModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
