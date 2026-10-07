import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics.dart';

import 'providers.dart';

/// Klíč pro `recordingArtworkProvider`: `releaseId`/`artistId` z jedné
/// nahrávky. Record type má vestavěnou strukturální `==`/`hashCode`, takže
/// funguje rovnou jako parametr `family` bez ruční implementace.
typedef ArtworkKey = ({String? releaseId, String? artistId});

/// Dohledá nejlepší dostupný obrázek pro nahrávku, která sama o sobě žádný
/// nenese -- `Recording` ve schématu (docs/openapi.yaml) nemá pole s
/// obrázkem, na rozdíl od `Artist`/`Release`. Zkusí nejdřív obal alba
/// (`releaseId`), a když album chybí -- typicky doporučení z ListenBrainz,
/// viz backend `RecommendationService._resolve_jspf_track`, které vždy
/// posílá `release_id=None` -- spadne na fotku interpreta. `null`, když ani
/// jedno není k dispozici nebo se dotaz nezdaří (chybějící obal je jen jiný
/// stav, ne chyba, kterou by volající musel řešit).
final recordingArtworkProvider = FutureProvider.autoDispose.family<String?, ArtworkKey>((ref, key) async {
  final repo = ref.watch(catalogRepositoryProvider);
  // Výsledek podržet 20 min i po odscrollování -- dřív se při návratu
  // v dlouhém seznamu (knihovna, fronta) posílal stejný dotaz znovu.
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 20), link.close);
  ref.onDispose(timer.cancel);

  if (key.releaseId != null) {
    // Skladba/album S albem: jen obal alba. Fotka interpreta jako "obal"
    // byla zavádějící -- u Deezeru je to navíc občas obal JINÉHO alba
    // (živě: Small Talk na iPhonu, "Jeder Rappen zählt" s fotkou kapely).
    try {
      // Jen obal (rychlé), ne celý detail alba -- ten čeká na MusicBrainz.
      return await repo.getReleaseCover(key.releaseId!);
    } catch (e, st) {
      final trace = st.toString().split('\n').take(6).join('\n');
      diagReport('artwork-release', '${key.releaseId}: $e\n$trace');
      return null;
    }
  }

  if (key.artistId != null) {
    try {
      final artist = await repo.getArtist(key.artistId!);
      return artist.coverImageUrl;
    } catch (_) {
      return null;
    }
  }

  return null;
});
