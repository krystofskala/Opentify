import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/toast.dart';
import 'favorite_artists_controller.dart';
import 'providers.dart';

/// Interpreti, které profil nechce slyšet (menu interpreta › Nelíbí se mi):
/// server je vyřadí ze všech mixů, rádií a doporučení (app/library/dislikes.py).
final dislikedArtistsProvider =
    AsyncNotifierProvider<DislikedArtistsController, Set<String>>(DislikedArtistsController.new);

class DislikedArtistsController extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final json = await ref.read(apiClientProvider).getJson('/library/disliked-artists');
    return (json['artistIds'] as List<dynamic>? ?? const []).cast<String>().toSet();
  }

  Future<void> toggle(BuildContext context, {required String id, required String name}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!state.hasValue) {
      try {
        await future;
      } catch (_) {}
    }
    final before = state.valueOrNull ?? const <String>{};
    final was = before.contains(id);
    // Server při "nelíbí se" interpreta odebere z oblíbených -- Zpět ho vrátí.
    final wasFavorite = ref.read(favoriteArtistsProvider.notifier).isFavorite(id);
    await _set(messenger, id: id, name: name, disliked: !was, restoreFavorite: false);
    if (!was) {
      showToast(
        messenger,
        '$name se už nebude objevovat v mixech',
        action: SnackBarAction(
          label: 'Zpět',
          onPressed: () => _set(messenger, id: id, name: name, disliked: false, restoreFavorite: wasFavorite),
        ),
      );
    }
  }

  Future<void> _set(
    ScaffoldMessengerState? messenger, {
    required String id,
    required String name,
    required bool disliked,
    required bool restoreFavorite,
  }) async {
    final before = state.valueOrNull ?? const <String>{};
    HapticFeedback.selectionClick();
    state = AsyncData(disliked ? {...before, id} : ({...before}..remove(id)));
    try {
      final api = ref.read(apiClientProvider);
      if (disliked) {
        await api.postJson('/library/disliked-artists/$id');
      } else {
        await api.deleteJson('/library/disliked-artists/$id');
        if (restoreFavorite) await api.postJson('/library/favorite-artists/$id');
        showToast(messenger, '$name se zase může objevovat v mixech');
      }
      // Server ho zároveň odebral z oblíbených a z hotových mixů.
      ref.invalidate(favoriteArtistsProvider);
      ref.invalidate(homeProvider);
    } catch (_) {
      state = AsyncData(before);
      showToast(messenger, 'Nepodařilo se uložit, zkus to znovu');
    }
  }
}
