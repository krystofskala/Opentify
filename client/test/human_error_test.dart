import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/api_client.dart';
import 'package:opentify_client/widgets/state_views.dart';

/// Toasty nikdy neukazují surové "ApiException(500): {...}" (UX audit).
void main() {
  test('chyby serveru a sítě jsou lidsky', () {
    expect(humanError(TimeoutException('x')), 'Server neodpověděl včas.');
    expect(humanError(Exception('ClientException: Failed to fetch')), contains('Tailscale'));
    expect(humanError(Exception('něco divného')), 'Zkus to prosím znovu.');
    expect(humanError(null), 'Zkus to prosím znovu.');
  });

  test('detail ze serveru má přednost', () {
    final e = ApiException(statusCode: 400, body: '{"detail": "název playlistu nesmí být prázdný"}');
    expect(humanError(e), 'název playlistu nesmí být prázdný');
    expect(humanError(ApiException(statusCode: 502, body: '<html>')), 'Server má potíže (502).');
  });
}
