import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_token.dart';
import '../core/page_location.dart';
import 'providers.dart';

typedef Profile = ({String id, String name, String role});

Profile? _profile(Object? j) {
  if (j is! Map<String, dynamic>) return null;
  return (id: j['id'] as String, name: j['name'] as String? ?? '', role: j['role'] as String? ?? 'user');
}

/// Kdo je na tomhle zařízení přihlášený (`user`) a za koho appka právě
/// jedná (`acting` -- admin se může přepnout na jiný profil).
///
/// `listenbrainzUser`: ListenBrainz účet profilu `acting` (null = nepřipojený;
/// jeho poslechy pak nikam nejdou -- nikdy ne do cizího účtu).
///
/// `inviteCode`: nepřihlášené zařízení otevřelo pozvánku (`/?join=KÓD`) --
/// přihlašovací obrazovka nabídne založení účtu (jméno + heslo si člověk
/// vybere sám, `/auth/claim`).
typedef AuthInfo = ({
  Profile? user,
  Profile? acting,
  String mode,
  String? listenbrainzUser,
  String? inviteCode,
});

/// Kdo je přihlášený (`GET /auth/me`). Režim `login`: jméno + heslo, klíč si
/// zařízení pamatuje. Starší režimy: pozvánka v adrese se jednou vymění za
/// klíč zařízení (`/auth/join`).
final authProvider = FutureProvider<AuthInfo>((ref) async {
  final api = ref.watch(apiClientProvider);
  final code = joinCodeFromUrl();
  var json = await api.getJson('/auth/me');
  final mode = json['mode'] as String? ?? 'open';
  if (code != null && mode != 'login') {
    try {
      final joined = await api.postJson('/auth/join', body: {'code': code});
      if (joined['token'] case final String token) await saveDeviceToken(token);
    } finally {
      clearJoinFromUrl();
    }
    json = await api.getJson('/auth/me');
  }
  // Nativní appka: klíč vydaný serverem si uložit (web má cookie).
  if (json['token'] case final String token) await saveDeviceToken(token);
  final user = _profile(json['user']);
  return (
    user: user,
    acting: _profile(json['acting']),
    mode: mode,
    listenbrainzUser: (json['acting'] as Map<String, dynamic>?)?['listenbrainzUser'] as String?,
    inviteCode: user == null && mode == 'login' ? code : null,
  );
});

/// Název tohohle zařízení pro přehled admina (posílá se při přihlášení).
String deviceName() {
  final platform = switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.android => 'Android',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.linux => 'Linux',
    _ => 'Zařízení',
  };
  return kIsWeb ? '$platform – prohlížeč' : '$platform – appka';
}

/// Admin: všechny profily.
typedef DeviceRow = ({String label, String lastUsedAt});
typedef ProfileRow = ({
  String id,
  String name,
  String role,
  int devices,
  String? username,
  bool hasPassword,
  List<DeviceRow> deviceList,
});

final profilesProvider = FutureProvider.autoDispose<List<ProfileRow>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/auth/users');
  return [
    for (final j in (json['items'] as List<dynamic>).cast<Map<String, dynamic>>())
      (
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        role: j['role'] as String? ?? 'user',
        devices: j['devices'] as int? ?? 0,
        username: j['username'] as String?,
        hasPassword: j['hasPassword'] as bool? ?? false,
        deviceList: [
          for (final d in (j['deviceList'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
            (label: d['label'] as String? ?? 'Zařízení', lastUsedAt: d['lastUsedAt'] as String? ?? ''),
        ],
      ),
  ];
});

/// Pozvánkový odkaz pro kód.
String inviteLink(String code) => '${appOrigin()}/?join=$code';
