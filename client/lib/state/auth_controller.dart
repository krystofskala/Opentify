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
typedef AuthInfo = ({Profile? user, Profile? acting, String mode});

/// Přihlášení: pozvánka v adrese (`/?join=KÓD`) se jednou vymění za klíč
/// zařízení (cookie), pak už jen `GET /auth/me`. Nic se nezadává.
final authProvider = FutureProvider<AuthInfo>((ref) async {
  final api = ref.watch(apiClientProvider);
  final code = joinCodeFromUrl();
  if (code != null) {
    try {
      final joined = await api.postJson('/auth/join', body: {'code': code});
      if (joined['token'] case final String token) await saveDeviceToken(token);
    } finally {
      clearJoinFromUrl();
    }
  }
  final json = await api.getJson('/auth/me');
  // Nativní appka: klíč vydaný serverem si uložit (web má cookie).
  if (json['token'] case final String token) await saveDeviceToken(token);
  return (
    user: _profile(json['user']),
    acting: _profile(json['acting']),
    mode: json['mode'] as String? ?? 'open',
  );
});

/// Admin: všechny profily.
typedef ProfileRow = ({String id, String name, String role, int devices});

final profilesProvider = FutureProvider.autoDispose<List<ProfileRow>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/auth/users');
  return [
    for (final j in (json['items'] as List<dynamic>).cast<Map<String, dynamic>>())
      (
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        role: j['role'] as String? ?? 'user',
        devices: j['devices'] as int? ?? 0,
      ),
  ];
});

/// Pozvánkový odkaz pro kód.
String inviteLink(String code) => '${appOrigin()}/?join=$code';
