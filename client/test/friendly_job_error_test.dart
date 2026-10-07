import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/state/provisioning_controller.dart';

void main() {
  test('technické chyby stahování se nahradí lidskou větou', () {
    expect(friendlyJobError(null), 'Skladbu se nepodařilo stáhnout');
    expect(friendlyJobError("yt-dlp nevytvořil očekávaný soubor /data/media/x.mp3"), 'Skladbu se nepodařilo stáhnout');
    expect(friendlyJobError("YouTube nemá 'X' v téhle verzi ({'id': 1})"), 'Skladbu se nepodařilo stáhnout');
    expect(friendlyJobError('slskd: žádný peer'), 'Skladbu se nepodařilo stáhnout');
    expect(friendlyJobError('Skladba není nikde k dispozici'), 'Skladba není nikde k dispozici');
  });
}
