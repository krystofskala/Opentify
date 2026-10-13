import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/listen_later_repository.dart' show LaterKind;
import '../state/listen_later_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;
import 'radio_station.dart';
import 'share_sheet.dart';
import '../state/disliked_artists_controller.dart';
import '../state/favorite_artists_controller.dart';
import '../features/artist/artist_screen.dart' show artistBioProvider, artistStatsProvider, discographyProvider;
import '../state/providers.dart' show apiClientProvider;
import 'state_views.dart' show humanError;
import 'toast.dart';

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
    final favorite =
        ref.watch(favoriteArtistsProvider.select((s) => s.valueOrNull?.any((a) => a.id == id) ?? false));
    final disliked = ref.watch(dislikedArtistsProvider.select((s) => s.valueOrNull?.contains(id) ?? false));

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
              favorite ? Symbols.heart_minus_rounded : Symbols.favorite_rounded,
              favorite ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
              () => ref
                  .read(favoriteArtistsProvider.notifier)
                  .toggle(hostContext, id: id, name: name, imageUrl: imageUrl),
            ),
            // Nelíbí se: pryč ze všech mixů, rádií a doporučení.
            // Ikona podle stavu, stejně jako menu skladby.
            row(
              disliked ? Symbols.heart_check_rounded : Symbols.heart_broken_rounded,
              disliked ? 'Zrušit „Nelíbí se mi“' : 'Nelíbí se mi',
              () => ref.read(dislikedArtistsProvider.notifier).toggle(hostContext, id: id, name: name),
            ),
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
            // 14. 10. (Journey): cizí fotka, nebo úplně jiný interpret stejného jména.
            row(Symbols.hide_image_rounded, 'Nahlásit špatnou fotku', () => _reportWrongPhoto(hostContext, ref, id)),
            row(Symbols.group_rounded, 'Je to jiný interpret…', () => _showNamesakes(hostContext, ref, id, name)),
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

Future<void> _reportWrongPhoto(BuildContext context, WidgetRef ref, String id) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final res = await ref.read(apiClientProvider).postJson('/catalog/artists/$id/wrong-photo');
    ref.invalidate(discographyProvider(id));
    showToast(messenger, res['found'] == true ? 'Fotka vyměněna' : 'Jinou fotku jsem nenašel – interpret je zatím bez fotky');
  } catch (e) {
    showToast(messenger, 'Nahlášení se nepovedlo: ${humanError(e)}');
  }
}

/// Ostatní interpreti stejného jména (nejznámější napřed) -- klepnutí
/// přepne na jeho stránku.
Future<void> _showNamesakes(BuildContext context, WidgetRef ref, String id, String name) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  List<dynamic> artists;
  try {
    final res = await ref.read(apiClientProvider).getJson('/catalog/artists/$id/namesakes');
    artists = (res['artists'] as List<dynamic>?) ?? const [];
  } catch (e) {
    showToast(messenger, 'Načtení se nepovedlo: ${humanError(e)}');
    return;
  }
  if (!context.mounted) return;
  if (artists.isEmpty) {
    showToast(messenger, 'Jiného interpreta jménem „$name“ jsem nenašel');
    return;
  }
  await showGlassSheet<void>(
    context,
    builder: (sheet) => GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Text('Interpreti jménem „$name“', style: Theme.of(sheet).textTheme.titleMedium),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final a in artists.cast<Map<String, dynamic>>())
              ListTile(
                dense: true,
                shape: AppShapes.md,
                leading: ClipOval(
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: ArtworkImage(url: a['imageUrl'] as String?, icon: Symbols.person_rounded, iconSize: 20),
                  ),
                ),
                title: Text(a['name'] as String? ?? name),
                subtitle: Text(_namesakeLine(a)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  context.push('/artists/${a['id']}');
                },
              ),
          ],
        ),
      ),
    ),
  );
  ref.invalidate(artistBioProvider(id));
  ref.invalidate(artistStatsProvider(id));
}

String _namesakeLine(Map<String, dynamic> a) {
  final parts = <String>[];
  final fans = a['fans'] as int?;
  if (fans != null) {
    parts.add(fans >= 1000000
        ? '${(fans / 1000000).toStringAsFixed(1).replaceAll('.', ',')} mil. fanoušků'
        : fans >= 1000
            ? '${(fans / 1000).round()} tis. fanoušků'
            : '$fans fanoušků');
  }
  final albums = a['albums'] as int?;
  if (albums != null) parts.add('$albums alb');
  return parts.isEmpty ? 'v knihovně' : parts.join(' · ');
}
