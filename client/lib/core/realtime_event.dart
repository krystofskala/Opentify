import '../models/playback_model.dart';

/// 1:1 s `channels./ws.subscribe` v docs/asyncapi.yaml — server->klient
/// zprávy. `sealed` umožňuje volajícím (viz state/playback_controller.dart,
/// state/provisioning_controller.dart) exhaustivní `switch` bez `default`
/// větve, kterou by šlo omylem zapomenout doplnit při rozšíření protokolu.
///
/// Backend (app/realtime.py) k datu psaní tohoto klienta reálně posílá jen
/// `TrackAvailableEvent`/`JobProgressEvent` (viz app/events.py) —
/// `playback.*`/`queue.*` je na serveru zatím jen TODO. Klient je ale
/// připraven na celý zdokumentovaný protokol, aby nemusel čekat na dopsání
/// backendu.
sealed class RealtimeEvent {
  const RealtimeEvent();

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final payload = (json['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    switch (type) {
      case 'playback.state':
        return PlaybackStateEvent(PlaybackSession.fromJson(payload));
      case 'queue.updated':
        return QueueUpdatedEvent(
          queue: _queueFromJson(payload['queue']),
          version: payload['version'] as int,
        );
      case 'queue.conflict':
        return QueueConflictEvent(
          reason: payload['reason'] as String? ?? 'unknown',
          currentQueue: _queueFromJson(payload['currentQueue']),
          currentVersion: payload['currentVersion'] as int,
        );
      case 'track.available':
        return TrackAvailableEvent(
          recordingId: payload['recordingId'] as String,
          streamUrl: payload['streamUrl'] as String,
        );
      case 'job.progress':
        return JobProgressEvent(
          jobId: payload['jobId'] as String,
          status: payload['status'] as String,
          pct: payload['pct'] as int?,
        );
      default:
        return UnknownEvent(type ?? '<chybí type>', payload);
    }
  }

  static List<QueueItem> _queueFromJson(Object? raw) => (raw as List<dynamic>? ?? const [])
      .map((e) => QueueItem.fromJson(e as Map<String, dynamic>))
      .toList();
}

final class PlaybackStateEvent extends RealtimeEvent {
  const PlaybackStateEvent(this.session);
  final PlaybackSession session;
}

final class QueueUpdatedEvent extends RealtimeEvent {
  const QueueUpdatedEvent({required this.queue, required this.version});
  final List<QueueItem> queue;
  final int version;
}

/// Klientův `queue.set` byl odmítnut kvůli zastaralé `expectedVersion` —
/// server posílá aktuální stav, na který si musí volající přepočítat svou
/// změnu a poslat `queue.set` znovu (viz PlaybackController.setQueue).
final class QueueConflictEvent extends RealtimeEvent {
  const QueueConflictEvent({
    required this.reason,
    required this.currentQueue,
    required this.currentVersion,
  });
  final String reason;
  final List<QueueItem> currentQueue;
  final int currentVersion;
}

final class TrackAvailableEvent extends RealtimeEvent {
  const TrackAvailableEvent({required this.recordingId, required this.streamUrl});
  final String recordingId;
  final String streamUrl;
}

final class JobProgressEvent extends RealtimeEvent {
  const JobProgressEvent({required this.jobId, required this.status, this.pct});
  final String jobId;
  final String status; // PENDING | RUNNING | SUCCEEDED | FAILED
  final int? pct;
}

final class UnknownEvent extends RealtimeEvent {
  const UnknownEvent(this.type, this.payload);
  final String type;
  final Map<String, dynamic> payload;
}
