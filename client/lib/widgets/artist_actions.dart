import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/listen_later_repository.dart' show LaterKind;
import '../state/listen_later_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import 'radio_station.dart';
import 'share_sheet.dart';

/// Menu interpreta -- stejné z ⋯ v hlavičce i dlouhým stiskem karty
/// interpreta kdekoli (Hledání, Knihovna, Podobní, Pokračovat). Audit UI:
/// dřív v hlavičce dvě nepopsaná kolečka a karty interpretů menu neměly.
Future<void> showArtistActions(BuildContext context, {required String id, required String name, String? imageUrl}) {
  HapticFeedback.selectionClick();
  return showGlassSheet<void>(
    context,
    builder: (_) => _ArtistActionsSheet(hostContext: context, id: id, name: name, imageUrl: imageUrl),
  );
}

class _ArtistActionsSheet extends ConsumerWidget {
  const _ArtistActionsSheet({required this.hostContext, required this.id, required this.name, this.imageUrl});

  final BuildContext hostContext;
  final String id;
  final String name;
  final String? imageUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final later = ref.watch(listenLaterProvider.select((s) => s.valueOrNull?.find(LaterKind.artist, id) != null));

    Widget row(IconData icon, String label, VoidCallback onTap) => ListTile(
          dense: true,
          shape: AppShapes.md,
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.of(context).pop();
            onTap();
          },
        );

    return GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Row(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: ArtworkImage(url: imageUrl, icon: Symbols.person_rounded, iconSize: 22),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            const Divider(height: 1),
            row(
              later ? Symbols.event_busy_rounded : Symbols.schedule_rounded,
              later ? 'Odebrat z „Na později“' : 'Uložit na později',
              () => ref.read(listenLaterProvider.notifier).toggle(hostContext, LaterKind.artist, id),
            ),
            row(Symbols.radio_rounded, 'Přejít na rádio', () => goToRadio(hostContext, RadioSeed.artist, id)),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xxs, horizontal: AppSpacing.md),
              child: Divider(height: 1),
            ),
            row(
              Symbols.ios_share_rounded,
              'Sdílet…',
              () => showShareSheet(hostContext, title: name, opentifyPath: '/artists/$id'),
            ),
          ],
        ),
      ),
    );
  }
}
