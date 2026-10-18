import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/realtime_event.dart';

RealtimeEvent event(String type, [Map<String, dynamic>? payload]) =>
    RealtimeEvent.fromJson({'type': type, if (payload != null) 'payload': payload});

void main() {
  test('prázdná zpráva a neznámé typy zachovají data', () {
    final empty = RealtimeEvent.fromJson({}) as UnknownEvent;
    expect(empty.type, '<chybí type>');
    expect(empty.payload, isEmpty);
    for (final type in ['', 'future.event']) {
      final unknown = event(type, {'nested': [1, null]}) as UnknownEvent;
      expect(unknown.type, type);
      expect(unknown.payload, {'nested': [1, null]});
    }
  });

  for (final type in ['devices.update', 'remote.command', 'handoff.request',
    'handoff.state', 'clock.pong', 'broadcast.prepare', 'broadcast.prepared',
    'broadcast.go', 'broadcast.future']) {
    test('$type je ConnectEvent včetně budoucích broadcast zpráv', () {
      final parsed = event(type, {'value': 42}) as ConnectEvent;
      expect(parsed.type, type);
      expect(parsed.payload, {'value': 42});
    });
  }

  test('fronta bez položek a konflikt s výchozím důvodem', () {
    for (final queue in [null, <dynamic>[]]) {
      final parsed = event('queue.updated', {'queue': queue, 'version': 0}) as QueueUpdatedEvent;
      expect(parsed.version, 0);
      expect(parsed.queue, isEmpty);
    }
    final conflict = event('queue.conflict', {'currentVersion': 7}) as QueueConflictEvent;
    expect(conflict.reason, 'unknown');
    expect(conflict.currentVersion, 7);
    expect(conflict.currentQueue, isEmpty);
    expect((event('queue.conflict', {'reason': 'stale', 'currentVersion': 8})
        as QueueConflictEvent).reason, 'stale');
  });

  test('dostupná a streamovaná skladba zachovají ID a URL', () {
    const payload = {'recordingId': 'r-1', 'streamUrl': '/stream/r-1'};
    final available = event('track.available', payload) as TrackAvailableEvent;
    expect(available.recordingId, 'r-1');
    expect(available.streamUrl, '/stream/r-1');
    final streaming = event('track.streaming', payload) as TrackStreamingEvent;
    expect(streaming.recordingId, 'r-1');
    expect(streaming.streamUrl, '/stream/r-1');
  });

  test('job: volitelná pole a krajní procenta', () {
    final minimal = event('job.progress', {'jobId': 'j', 'status': 'PENDING'}) as JobProgressEvent;
    expect(minimal.pct, isNull);
    expect(minimal.error, isNull);
    for (final pct in [0, 100]) {
      final parsed = event('job.progress', {
        'jobId': 'j', 'status': 'FAILED', 'pct': pct, 'error': 'Nenalezeno',
      }) as JobProgressEvent;
      expect(parsed.jobId, 'j');
      expect(parsed.status, 'FAILED');
      expect(parsed.pct, pct);
      expect(parsed.error, 'Nenalezeno');
    }
  });

  test('neplatné typy JSON a chybějící povinná pole jsou odmítnuty', () {
    final invalid = <Map<String, dynamic>>[
      {'type': 1}, {'type': 'future', 'payload': []},
      {'type': 'track.available'}, {'type': 'track.streaming'},
      {'type': 'job.progress', 'payload': {'jobId': 'j', 'status': 'RUNNING', 'pct': 0.5}},
      {'type': 'queue.updated', 'payload': {'version': '1'}},
      {'type': 'queue.updated', 'payload': {'version': 1, 'queue': {}}},
      {'type': 'queue.updated', 'payload': {'version': 1, 'queue': [null]}},
      {'type': 'queue.conflict', 'payload': {}},
    ];
    for (final json in invalid) {
      expect(() => RealtimeEvent.fromJson(json), throwsA(isA<TypeError>()), reason: '$json');
    }
  });
}
