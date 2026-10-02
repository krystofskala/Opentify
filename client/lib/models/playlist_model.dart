import '../core/media_url.dart';
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
    this.description,
    this.coverUrls = const [],
    this.role,
    this.members = const [],
    this.addedBy = const {},
  });

  final String id;
  final String title;
  final String kind; // USER | GENERATED_RECOMMENDATION | RADIO
  final String? source;
  final DateTime? generatedAt;
  final int itemCount;
  final List<RecordingModel> items;
  final String? description;

  /// Až 4 obaly pro mozaiku (žebříčky/mixy z Domů).
  final List<String> coverUrls;

  /// Žebříčky, žánry, výběry a mixy z Domů -- jen číst ("Přidat do knihovny"
  /// udělá vlastní kopii). Upravovat jde jen `USER` playlist.
  bool get isReadOnly => kind != 'USER';

  /// Společný playlist: "owner" / "member", jinak null.
  final String? role;
  final List<String> members;

  /// Kdo kterou skladbu přidal (recording id -> jméno).
  final Map<String, String> addedBy;

  bool get isCollab => members.isNotEmpty;
  bool get isMember => role == 'member';

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
        description: json['description'] as String?,
        role: json['role'] as String?,
        members: (json['members'] as List<dynamic>? ?? const []).cast<String>(),
        addedBy: (json['addedBy'] as Map<String, dynamic>? ?? const {}).cast<String, String>(),
        coverUrls: resolveMediaUrls((json['coverUrls'] as List<dynamic>? ?? const []).cast<String>()),
      );
}
