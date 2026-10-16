import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/realtime_event.dart';

/// Regrese 16. 10.: zprávy bariéry (`broadcast.prepare`, `prepared`, `go`...)
/// končily jako UnknownEvent a controller je nikdy nedostal.
void main() {
  test('všechny zprávy sdíleného streamu a hodin jdou do Connect', () {
    for (final type in [
      'clock.pong',
      'broadcast.state',
      'broadcast.started',
      'broadcast.pending',
      'broadcast.ended',
      'broadcast.listeners',
      'broadcast.taken',
      'broadcast.error',
      'broadcast.prepare',
      'broadcast.prepared',
      'broadcast.go',
      'broadcast.added',
      'broadcast.add_result',
      'broadcasts.update',
    ]) {
      final e = RealtimeEvent.fromJson({'type': type, 'payload': <String, dynamic>{}});
      expect(e, isA<ConnectEvent>(), reason: type);
      expect((e as ConnectEvent).type, type);
    }
  });
}
