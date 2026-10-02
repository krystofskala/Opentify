import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/media_url.dart';
import '../widgets/toast.dart';
import 'providers.dart';

/// Oblíbený interpret (Knihovna › Interpreti › Oblíbení).
typedef FavoriteArtist = ({String id, String name, String? imageUrl, String? addedAt});

/// Oblíbení interpreti profilu -- srdíčko v hlavičce interpreta a v jeho menu.
final favoriteArtistsProvider =
    AsyncNotifierProvider<FavoriteArtistsController, List<FavoriteArtist>>(FavoriteArtistsController.new);

class FavoriteArtistsController extends AsyncNotifier<List<FavoriteArtist>> {
  @override
  Future<List<FavoriteArtist>> build() async {
    final rows = await ref.read(apiClientProvider).getJsonList('/library/favorite-artists');
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        (
          id: r['id'] as String,
          name: r['name'] as String? ?? '',
          imageUrl: resolveMediaUrl(r['imageUrl'] as String?),
          addedAt: r['addedAt'] as String?,
        ),
    ];
  }

  bool isFavorite(String artistId) => state.valueOrNull?.any((a) => a.id == artistId) ?? false;

  Future<void> toggle(BuildContext context, {required String id, required String name, String? imageUrl}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final was = isFavorite(id);
    HapticFeedback.selectionClick();
    final before = state.valueOrNull ?? const [];
    // Hned v UI, server dožene.
    state = AsyncData(
      was
          ? [for (final a in before) if (a.id != id) a]
          : [(id: id, name: name, imageUrl: imageUrl, addedAt: DateTime.now().toIso8601String()), ...before],
    );
    try {
      final api = ref.read(apiClientProvider);
      if (was) {
        await api.deleteJson('/library/favorite-artists/$id');
      } else {
        await api.postJson('/library/favorite-artists/$id');
      }
      showToast(messenger, was ? 'Odebráno z oblíbených: $name' : 'V oblíbených: $name');
    } catch (_) {
      state = AsyncData(before);
      showToast(messenger, 'Nepodařilo se uložit, zkus to znovu');
    }
  }
}
