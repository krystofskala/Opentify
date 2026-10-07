import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// "Nepočítat do vkusu" (menu ⋯ skladby a playlistu): poslech zůstává ve
/// Wrapped a historii, jen doporučování ho nebere (puštěno pro někoho, na
/// usínání...). `GET/POST /home/taste-exclusions`.
typedef TasteExclusions = ({Set<String> recordings, Set<String> playlists});

final tasteExclusionsProvider = FutureProvider<TasteExclusions>((ref) async {
  final json = await ref.read(apiClientProvider).getJson('/home/taste-exclusions');
  Set<String> ids(String key) => {for (final v in (json[key] as List<dynamic>? ?? const [])) v as String};
  return (recordings: ids('recordings'), playlists: ids('playlists'));
});

/// Přepne a vrátí nový stav (true = nepočítá se).
Future<bool> setTasteExclusion(WidgetRef ref, {required String kind, required String id, required bool excluded}) async {
  await ref
      .read(apiClientProvider)
      .postJson('/home/taste-exclusions', body: {'kind': kind, 'id': id, 'excluded': excluded});
  ref.invalidate(tasteExclusionsProvider);
  ref.invalidate(homeProvider);
  return excluded;
}
