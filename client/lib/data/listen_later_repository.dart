import '../core/api_client.dart';
import '../core/media_url.dart';
import '../models/recording_model.dart';
import 'home_repository.dart';

/// Druh položky "Poslechnout později".
enum LaterKind { track, album, artist }

LaterKind _kindFrom(String raw) => switch (raw) {
      'album' => LaterKind.album,
      'artist' => LaterKind.artist,
      _ => LaterKind.track,
    };

class LaterArtist {
  const LaterArtist({required this.id, required this.name, this.imageUrl});
  final String id;
  final String name;
  final String? imageUrl;
}

/// Jedna položka seznamu -- skladba, album nebo interpret (viz backend
/// app/listen_later.py).
class LaterItem {
  const LaterItem({
    required this.id,
    required this.kind,
    required this.addedAt,
    this.note,
    this.source,
    this.listenedAt,
    this.track,
    this.album,
    this.artist,
  });

  final String id;
  final LaterKind kind;
  final String? note;

  /// Odkud položka přišla: `null` = ručně, `'shazam'` = Open Shazam.
  final String? source;
  final DateTime addedAt;
  final DateTime? listenedAt;
  final RecordingModel? track;
  final HomeAlbumCard? album;
  final LaterArtist? artist;

  /// Id skladby / alba / interpreta, na které položka ukazuje.
  String get targetId => track?.id ?? album?.id ?? artist!.id;

  String get title => track?.title ?? album?.title ?? artist!.name;

  bool get fromShazam => source == 'shazam';

  factory LaterItem.fromJson(Map<String, dynamic> j) {
    final artist = j['artist'] as Map<String, dynamic>?;
    return LaterItem(
      id: j['id'] as String,
      kind: _kindFrom(j['kind'] as String),
      note: j['note'] as String?,
      source: j['source'] as String?,
      addedAt: DateTime.parse(j['addedAt'] as String),
      listenedAt: j['listenedAt'] == null ? null : DateTime.parse(j['listenedAt'] as String),
      track: j['track'] == null ? null : RecordingModel.fromJson(j['track'] as Map<String, dynamic>),
      album: j['album'] == null ? null : HomeAlbumCard.fromJson(j['album'] as Map<String, dynamic>),
      artist: artist == null
          ? null
          : LaterArtist(
              id: artist['id'] as String,
              name: artist['name'] as String,
              imageUrl: resolveMediaUrl(((artist['images'] as List<dynamic>?) ?? const []).cast<String?>().firstOrNull),
            ),
    );
  }
}

class LaterList {
  const LaterList({this.active = const [], this.listened = const [], this.reminder});

  final List<LaterItem> active;
  final List<LaterItem> listened;

  /// Něco, co v seznamu leží přes 2 týdny -- připomínka na Domů.
  final LaterItem? reminder;

  LaterItem? find(LaterKind kind, String targetId) {
    for (final item in active) {
      if (item.kind == kind && item.targetId == targetId) return item;
    }
    return null;
  }
}

class ListenLaterRepository {
  ListenLaterRepository(this._api);

  final ApiClient _api;

  Future<LaterList> list() async {
    final j = await _api.getJson('/listen-later');
    List<LaterItem> items(String key) =>
        (j[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>().map(LaterItem.fromJson).toList();
    return LaterList(
      active: items('active'),
      listened: items('listened'),
      reminder: j['reminder'] == null ? null : LaterItem.fromJson(j['reminder'] as Map<String, dynamic>),
    );
  }

  Future<LaterItem> add(LaterKind kind, String targetId, {String? note}) async => LaterItem.fromJson(
        await _api
            .postJson('/listen-later', body: {'kind': kind.name, 'targetId': targetId, if (note != null) 'note': note}),
      );

  Future<void> setNote(String itemId, String note) => _api.patchJson('/listen-later/$itemId', body: {'note': note});

  Future<void> restore(String itemId) => _api.patchJson('/listen-later/$itemId', body: {'restore': true});

  Future<void> remove(String itemId) => _api.deleteJson('/listen-later/$itemId');
}
