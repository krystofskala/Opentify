import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/playlists_repository.dart';
import '../state/providers.dart';
import 'glass/glass.dart';
import 'toast.dart';

/// Odebrání playlistu z Knihovny -- jedno místo pro detail i karty v Knihovně:
/// vlastní se smaže (s potvrzením), připnutý mix odepne, ze společného
/// (člen) se odejde.
Future<bool> confirmDeletePlaylist(BuildContext context, WidgetRef ref, {required String id, required String title}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Smazat „$title“?'),
      content: const Text('Tohle nejde vrátit zpátky.'),
      actions: [
        GlassButton(
          label: 'Zrušit',
          style: GlassButtonStyle.plain,
          compact: true,
          onPressed: () => Navigator.of(dialog).pop(false),
        ),
        GlassButton(
          label: 'Smazat',
          destructive: true,
          compact: true,
          onPressed: () => Navigator.of(dialog).pop(true),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    await ref.read(playlistsRepositoryProvider).delete(id);
    ref.invalidate(myPlaylistsProvider);
    showToast(messenger, '„$title“ smazán');
    return true;
  } catch (e) {
    showToast(messenger, 'Smazat se nepodařilo: $e');
    return false;
  }
}

Future<bool> unpinPlaylist(BuildContext context, WidgetRef ref, {required String id, required String title}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(playlistsRepositoryProvider).unpin(id);
    ref.invalidate(myPlaylistsProvider);
    showToast(messenger, '„$title“ odebrán z knihovny');
    return true;
  } catch (e) {
    showToast(messenger, 'Nepodařilo se: $e');
    return false;
  }
}

Future<bool> leavePlaylist(BuildContext context, WidgetRef ref, {required String id, required String title}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(apiClientProvider).deleteJson('/playlists/$id/members/me');
    ref.invalidate(myPlaylistsProvider);
    showToast(messenger, 'Opustil(a) jsi „$title“');
    return true;
  } catch (e) {
    showToast(messenger, 'Nepodařilo se: $e');
    return false;
  }
}

/// Správná akce odebrání podle druhu playlistu v Knihovně.
({String label, Future<bool> Function() run}) removalFor(BuildContext context, WidgetRef ref, PlaylistSummaryModel p) {
  if (p.pinned) {
    return (label: 'Odebrat z knihovny', run: () => unpinPlaylist(context, ref, id: p.id, title: p.title));
  }
  if (p.member || (p.collab && p.ownerName != null)) {
    return (label: 'Opustit společný playlist', run: () => leavePlaylist(context, ref, id: p.id, title: p.title));
  }
  return (label: 'Smazat playlist', run: () => confirmDeletePlaylist(context, ref, id: p.id, title: p.title));
}
