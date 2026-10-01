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

  if (key.releaseId != null) {
    try {
      final release = await repo.getRelease(key.releaseId!);
      if (release.coverImageUrl != null) return release.coverImageUrl;
    } catch (e, st) {
      // Album se nedohledalo -- zkusíme ještě interpreta níž. Nahlásit:
      // na iPhonu tak naskočila fotka interpreta místo obalu (živě).
      final trace = st.toString().split('\n').take(6).join('\n');
      diagReport('artwork-release', '${key.releaseId}: $e\n$trace');
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
