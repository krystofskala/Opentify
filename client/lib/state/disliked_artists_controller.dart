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
    HapticFeedback.selectionClick();
    state = AsyncData(was ? ({...before}..remove(id)) : {...before, id});
    try {
      final api = ref.read(apiClientProvider);
      if (was) {
        await api.deleteJson('/library/disliked-artists/$id');
      } else {
        await api.postJson('/library/disliked-artists/$id');
      }
      // Server ho zároveň odebral z oblíbených a z hotových mixů.
      ref.invalidate(favoriteArtistsProvider);
      ref.invalidate(homeProvider);
      showToast(messenger, was ? '$name se zase může objevovat v mixech' : '$name se už nebude objevovat v mixech');
    } catch (_) {
      state = AsyncData(before);
      showToast(messenger, 'Nepodařilo se uložit, zkus to znovu');
    }
  }
}
