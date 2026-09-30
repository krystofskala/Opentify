import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/playlists_repository.dart';
import '../state/providers.dart';
import 'glass/glass.dart';

/// Import z odkazu na Spotify: průběh, pak otevře nový playlist a řekne,
/// kolik skladeb se našlo (a jestli Spotify dal jen prvních 100).
Future<void> importSpotifyLink(BuildContext context, WidgetRef ref, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.of(context);
  messenger?.showSnackBar(
    const SnackBar(content: Text('Načítám ze Spotify…'), duration: Duration(seconds: 30)),
  );
  try {
    final result = await ref.read(playlistsRepositoryProvider).importSpotifyLink(url.trim());
    ref.invalidate(myPlaylistsProvider);
    messenger?.hideCurrentSnackBar();
    final count = result.matched == result.total
        ? '${result.total} skladeb'
        : '${result.matched} z ${result.total} skladeb';
    messenger?.showSnackBar(SnackBar(
      content: Text(
        '„${result.title}“ je v Knihovně › Sdílené ($count).'
        '${result.truncated ? ' Spotify veřejně ukazuje jen prvních 100.' : ''}',
      ),
    ));
    router.push('/playlists/${result.id}');
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    final detail = e.toString();
    messenger?.showSnackBar(SnackBar(
      content: Text(detail.contains('Spotify') ? detail.replaceFirst(RegExp(r'^[^:]*:\s*'), '') : 'Import ze Spotify se nepovedl.'),
    ));
  }
}

/// Dialog "Přidat ze Spotify": vložit odkaz (nabídne obsah schránky, když
/// v ní odkaz je).
Future<void> showSpotifyLinkDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  try {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text ?? '';
    if (looksLikeSpotifyLink(text)) controller.text = text.trim();
  } catch (_) {
    // Schránka nedostupná (prohlížeč nepovolil) -- vloží se ručně.
  }
  if (!context.mounted) return;
  final url = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Přidat ze Spotify'),
      content: TextField(
        controller: controller,
        autofocus: controller.text.isEmpty,
        decoration: const InputDecoration(hintText: 'Odkaz na playlist, album nebo skladbu'),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Zrušit')),
        GlassButton(
          label: 'Přidat',
          style: GlassButtonStyle.prominent,
          compact: true,
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
        ),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  await importSpotifyLink(context, ref, url);
}
