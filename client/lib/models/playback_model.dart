/// 1:1 s `components.schemas.QueueItem`/`PlaybackSession` v docs/asyncapi.yaml.
class QueueItem {
  const QueueItem({required this.recordingId, required this.position});

  final String recordingId;
  final int position;

  factory QueueItem.fromJson(Map<String, dynamic> json) => QueueItem(
        recordingId: json['recordingId'] as String,
        position: json['position'] as int,
      );

  Map<String, dynamic> toJson() => {'recordingId': recordingId, 'position': position};
}

enum RepeatMode { off, one, all }

RepeatMode _repeatModeFromJson(String? value) => switch (value) {
      'one' => RepeatMode.one,
      'all' => RepeatMode.all,
      _ => RepeatMode.off,
    };

class PlaybackSession {
  const PlaybackSession({
    this.activeDeviceId,
    this.currentRecordingId,
    required this.positionMs,
    required this.isPlaying,
    required this.repeatMode,
    required this.shuffle,
    required this.queue,
    required this.version,
  });

  const PlaybackSession.empty()
      : activeDeviceId = null,
        currentRecordingId = null,
        positionMs = 0,
        isPlaying = false,
        repeatMode = RepeatMode.off,
        shuffle = false,
        queue = const [],
        version = 0;

  final String? activeDeviceId;
  final String? currentRecordingId;
  final int positionMs;
  final bool isPlaying;
  final RepeatMode repeatMode;
  final bool shuffle;
  final List<QueueItem> queue;
  final int version;

  factory PlaybackSession.fromJson(Map<String, dynamic> json) => PlaybackSession(
        activeDeviceId: json['activeDeviceId'] as String?,
        currentRecordingId: json['currentRecordingId'] as String?,
        positionMs: json['positionMs'] as int? ?? 0,
        isPlaying: json['isPlaying'] as bool? ?? false,
        repeatMode: _repeatModeFromJson(json['repeatMode'] as String?),
        shuffle: json['shuffle'] as bool? ?? false,
        queue: (json['queue'] as List<dynamic>? ?? const [])
            .map((e) => QueueItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        version: json['version'] as int? ?? 0,
      );

  PlaybackSession copyWith({
    String? activeDeviceId,
    String? currentRecordingId,
    int? positionMs,
    bool? isPlaying,
    RepeatMode? repeatMode,
    bool? shuffle,
    List<QueueItem>? queue,
    int? version,
  }) {
    return PlaybackSession(
      activeDeviceId: activeDeviceId ?? this.activeDeviceId,
      currentRecordingId: currentRecordingId ?? this.currentRecordingId,
      positionMs: positionMs ?? this.positionMs,
      isPlaying: isPlaying ?? this.isPlaying,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      queue: queue ?? this.queue,
      version: version ?? this.version,
    );
  }
}
