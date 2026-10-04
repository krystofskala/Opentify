import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/config.dart';
import '../data/playlists_repository.dart';
import '../state/providers.dart';
import '../theme/design_tokens.dart';
import 'collection_actions.dart';
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

/// Pozvat do společného playlistu: odkaz s kódem (seznam profilů se
/// nikomu neukazuje). Kdo ho otevře, může přidávat a odebírat skladby.
Future<void> invitePlaylist(BuildContext context, WidgetRef ref, {required String id}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final res = await ref.read(apiClientProvider).postJson('/playlists/$id/invite');
    final url = '${AppConfig.sharedOrigin}/#${res['path']}'; // router je hashový (jako share_link)
    await Clipboard.setData(ClipboardData(text: url));
    showToast(messenger, 'Odkaz na společný playlist zkopírován – pošli ho, kdo ho otevře, může ho upravovat s tebou');
  } catch (e) {
    showToast(messenger, 'Pozvánku se nepodařilo vytvořit: $e');
  }
}

/// ⋯ › Upravit: název, krátký popis a vlastní obal (místo mozaiky).
Future<void> editPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String title,
  String? description,
  VoidCallback? onSaved,
}) async {
  final titleField = TextEditingController(text: title);
  final descriptionField = TextEditingController(text: description ?? '');
  final messenger = ScaffoldMessenger.maybeOf(context);
  final api = ref.read(apiClientProvider);
  final saved = await showGlassSheet<bool>(
    context,
    builder: (sheet) => GlassSheet(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md + MediaQuery.viewInsetsOf(sheet).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Upravit playlist', style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: titleField, decoration: const InputDecoration(labelText: 'Název')),
            const SizedBox(height: AppSpacing.xs),
            TextField(
              controller: descriptionField,
              maxLines: 3,
              minLines: 1,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Krátký popis (nepovinné)'),
            ),
            Row(
              children: [
                Expanded(
                  child: GlassButton(
                    label: 'Vybrat obal…',
                    icon: Symbols.image_rounded,
                    style: GlassButtonStyle.tonal,
                    onPressed: () async {
                      final picked = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
                      final file = picked?.files.firstOrNull;
                      if (file?.bytes == null) return;
                      try {
                        await api.postMultipart('/playlists/$id/cover',
                            fieldName: 'file', bytes: file!.bytes!, filename: file.name);
                        showToast(messenger, 'Obal nastaven');
                      } catch (e) {
                        showToast(messenger, 'Obal se nepodařilo nahrát: $e');
                      }
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                GlassButton(
                  label: 'Mozaika',
                  icon: Symbols.grid_view_rounded,
                  style: GlassButtonStyle.plain,
                  onPressed: () async {
                    try {
                      await api.deleteJson('/playlists/$id/cover');
                      showToast(messenger, 'Zpátky na mozaiku z obalů skladeb');
                    } catch (_) {}
                  },
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            GlassButton(
              label: 'Uložit',
              style: GlassButtonStyle.prominent,
              expand: true,
              onPressed: () => Navigator.of(sheet).pop(true),
            ),
          ],
        ),
      ),
    ),
  );
  if (saved == true) {
    try {
      await api.patchJson('/playlists/$id', body: {
        'title': titleField.text.trim(),
        'description': descriptionField.text.trim(),
      });
    } catch (e) {
      showToast(messenger, 'Uložení selhalo: $e');
    }
  }
  titleField.dispose();
  descriptionField.dispose();
  ref.invalidate(myPlaylistsProvider);
  onSaved?.call();
}

/// Menu playlistu -- JEDNO pro ⋯ v detailu i dlouhý stisk v Knihovně (dřív
/// Knihovna nenabízela Upravit/Pozvat a odchod ze společného měla jen jako
/// "Smazat"). `onGone` po smazání / opuštění (detail se zavře).
Future<void> showPlaylistActions(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String title,
  String? description,
  String? imageUrl,
  required bool readOnly,
  required bool member,
  bool pinned = false,
  bool isRadio = false,
  VoidCallback? onSaveCopy,
  VoidCallback? onChanged,
  VoidCallback? onGone,
}) {
  final own = !readOnly && !member;
  return showCollectionActions(
    context,
    kind: CollectionKind.playlist,
    id: id,
    title: title,
    subtitle: description,
    imageUrl: imageUrl,
    isRadio: isRadio,
    onSaveCopy: onSaveCopy,
    onEdit: own
        ? () => editPlaylist(context, ref, id: id, title: title, description: description, onSaved: onChanged)
        : null,
    onInvite: own ? () => invitePlaylist(context, ref, id: id) : null,
    onLeave: member
        ? () async {
            if (await leavePlaylist(context, ref, id: id, title: title)) onGone?.call();
          }
        : null,
    // Vlastní se maže; připnutý mix se jen odepne z knihovny.
    onDelete: own
        ? () async {
            if (await confirmDeletePlaylist(context, ref, id: id, title: title)) onGone?.call();
          }
        : pinned && !member
            ? () => unpinPlaylist(context, ref, id: id, title: title)
            : null,
    deleteLabel: own ? null : 'Odebrat z knihovny',
  );
}

/// Dlouhý stisk na playlistu v Knihovně (souhrn místo detailu).
Future<void> showPlaylistSummaryActions(BuildContext context, WidgetRef ref, PlaylistSummaryModel p) =>
    showPlaylistActions(
      context,
      ref,
      id: p.id,
      title: p.title,
      description: p.description,
      imageUrl: p.coverUrls.firstOrNull,
      readOnly: p.kind != 'USER',
      member: p.member || (p.collab && p.ownerName != null),
      pinned: p.pinned,
      isRadio: p.source?.startsWith('radio:') ?? false,
    );
