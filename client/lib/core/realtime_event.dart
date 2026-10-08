import '../models/playback_model.dart';

/// 1:1 s `channels./ws.subscribe` v docs/asyncapi.yaml — server->klient
/// zprávy. `sealed` umožňuje volajícím (viz
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
      case 'track.streaming':
        return TrackStreamingEvent(
          recordingId: payload['recordingId'] as String,
          streamUrl: payload['streamUrl'] as String,
        );
      case 'job.progress':
        return JobProgressEvent(
          jobId: payload['jobId'] as String,
          status: payload['status'] as String,
          pct: payload['pct'] as int?,
          error: payload['error'] as String?,
        );
      // Opentify Connect (app/realtime.py): seznam zařízení profilu, povely
      // a předání přehrávání mezi nimi.
      case 'devices.update' || 'remote.command' || 'handoff.request' || 'handoff.state':
        return ConnectEvent(type!, payload);
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
/// změnu a poslat `queue.set` znovu.
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

/// Soubor se ještě stahuje, ale `streamUrl` je už servírovatelný -- backend
/// (`_tail_growing_file`) servíruje ještě rostoucí soubor. Posílá se jen z
/// `SlskdProvider` cesty (stahuje rovnou ve finálním formátu), ne z YouTube
/// fallbacku (ten potřebuje dokončit ffmpeg konverzi, viz `OnFileLocated`
/// v backendu). `ProvisioningController`/`AudioPlayerController` na tenhle
/// event reagují stejně jako na `TrackAvailableEvent` -- viz jejich komentáře.
final class TrackStreamingEvent extends RealtimeEvent {
  const TrackStreamingEvent({required this.recordingId, required this.streamUrl});
  final String recordingId;
  final String streamUrl;
}

final class JobProgressEvent extends RealtimeEvent {
  const JobProgressEvent({required this.jobId, required this.status, this.pct, this.error});
  final String jobId;
  final String status; // PENDING | RUNNING | SUCCEEDED | FAILED
  final int? pct;
  /// Důvod konečného selhání pro uživatele ("Tuhle verzi nemáme").
  final String? error;
}

final class ConnectEvent extends RealtimeEvent {
  const ConnectEvent(this.type, this.payload);
  final String type;
  final Map<String, dynamic> payload;
}

final class UnknownEvent extends RealtimeEvent {
  const UnknownEvent(this.type, this.payload);
  final String type;
  final Map<String, dynamic> payload;
}
