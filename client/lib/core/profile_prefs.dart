import 'package:shared_preferences/shared_preferences.dart';

/// Stav v úložišti zařízení, který patří PROFILU, ne zařízení -- po
/// přepnutí profilu (admin) nebo odhlášení by jinak další profil dostal
/// cizí frontu, historii hledání, rozposlouchaná alba i pohled Knihovny.
const profileScopedPrefKeys = [
  'player.session.v1',
  'player.session.queue.v1',
  'player.collection_progress',
  'search_history',
  'library.scope',
];

/// Čí stav v úložišti je (id profilu z `/auth/me`).
const _ownerKey = 'device.prefs_profile';

/// Zvyšuje se smazáním -- kontrolery, které vznikly před ním (starý profil
/// do restartu appky ještě běží), už nic nezapíšou zpátky.
int profilePrefsGeneration = 0;

/// Před přepnutím profilu / odhlášením.
Future<void> clearProfilePrefs() async {
  profilePrefsGeneration++;
  try {
    final prefs = await SharedPreferences.getInstance();
    for (final key in profileScopedPrefKeys) {
      await prefs.remove(key);
    }
    await prefs.remove(_ownerKey);
  } catch (_) {}
}

/// Po načtení `/auth/me`: patří uložený stav jinému profilu (odhlášení
/// mimo appku, jiné přihlášení), smaže se. Bez vlastníka (starší verze)
/// si ho převezme současný profil.
Future<void> claimProfilePrefs(String profileId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final owner = prefs.getString(_ownerKey);
    if (owner == profileId) return;
    if (owner != null) {
      for (final key in profileScopedPrefKeys) {
        await prefs.remove(key);
      }
    }
    await prefs.setString(_ownerKey, profileId);
  } catch (_) {}
}
