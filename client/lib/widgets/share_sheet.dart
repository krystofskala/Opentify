import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/share_link.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'track_actions.dart' show shareWithToast;

/// Jediné „Sdílet…" v celé appce (audit UI: dřív 2–3 různé sdílecí položky
/// a ikony vedle sebe). Nabídne:
/// - Poslat v Opentify (otevře se přímo v Opentify -- pro lidi se sdíleným
///   Opentify),
/// - Odkaz pro jiné aplikace (Spotify, Apple Music, YouTube…),
/// - Jako obrázek (jen kde to jde -- skladba / přehrávač).
Future<void> showShareSheet(
  BuildContext context, {
  required String title,
  String? artistName,
  String? opentifyPath,
  ShareTarget? external,
  VoidCallback? asImage,
}) {
  return showGlassSheet<void>(
    context,
    builder: (_) => _ShareSheet(
      hostContext: context,
      title: title,
      artistName: artistName,
      opentifyPath: opentifyPath,
      external: external,
      asImage: asImage,
    ),
  );
}

class _ShareSheet extends ConsumerWidget {
  const _ShareSheet({
    required this.hostContext,
    required this.title,
    required this.artistName,
    required this.opentifyPath,
    required this.external,
    required this.asImage,
  });

  final BuildContext hostContext;
  final String title;
  final String? artistName;
  final String? opentifyPath;
  final ShareTarget? external;
  final VoidCallback? asImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.maybeOf(hostContext);
    // Načíst hned -- Safari sdílí jen přímo z klepnutí, ne po síťovém čekání.
    final link = external == null ? null : ref.watch(shareLinkProvider(external!));
    final hasExternal = external != null &&
        !(link?.hasValue == true && link!.value!.primaryUrl == null);

    Widget row(IconData icon, String label, String hint, VoidCallback onTap) => ListTile(
          dense: true,
          shape: AppShapes.md,
          leading: Icon(icon),
          title: Text(label),
          subtitle: Text(hint),
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text(
                artistName == null ? 'Sdílet „$title“' : 'Sdílet „$title“ – $artistName',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (opentifyPath != null)
              row(Symbols.send_rounded, 'Poslat v Opentify', 'Otevře se rovnou v Opentify', () {
                shareInOpentifyWithToast(messenger, path: opentifyPath!, title: title, artistName: artistName);
              }),
            if (hasExternal)
              row(Symbols.link_rounded, 'Odkaz pro jiné aplikace', 'Spotify, Apple Music, YouTube…', () {
                shareWithToast(link?.valueOrNull, messenger, () => ref.read(shareLinkProvider(external!).future));
              }),
            if (asImage != null)
              row(Symbols.image_rounded, 'Jako obrázek', 'Obal nebo text – třeba do stories', asImage!),
          ],
        ),
      ),
    );
  }
}
