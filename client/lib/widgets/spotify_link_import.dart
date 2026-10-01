import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../data/playlists_repository.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import 'track_actions.dart' show nowPlayingInfoFor;
import 'glass/glass.dart';
import '../core/cz_plural.dart';

/// Import z odkazu na Spotify: průběh, pak otevře nový playlist a řekne,
/// kolik skladeb se našlo (a jestli Spotify dal jen prvních 100).
Future<void> importSpotifyLink(BuildContext context, WidgetRef ref, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.of(context);
  messenger?.showSnackBar(
    const SnackBar(content: Text('Načítám odkaz…'), duration: Duration(minutes: 3)),
  );
  try {
    final result = await ref.read(playlistsRepositoryProvider).importSpotifyLink(url.trim());
    messenger?.hideCurrentSnackBar();
    if (result.isTrack) {
      // Jedna skladba: rovnou pustit (stáhne se, když ještě není).
      final rec = result.recording;
      if (rec == null) throw Exception('Skladbu se nepodařilo najít.');
      void play() => ref
          .read(audioPlayerControllerProvider.notifier)
          .playTrack(nowPlayingInfoFor(rec), sourceLabel: 'Sdílená skladba');
      // Safari po await už nemusí brát přehrání jako gesto uživatele --
      // zkusí se hned, a kdyby to zablokoval, snackbar má tlačítko.
      play();
      messenger?.showSnackBar(SnackBar(
        content: Text(rec.title),
        action: SnackBarAction(label: 'Přehrát', onPressed: play),
      ));
      return;
    }
    ref.invalidate(myPlaylistsProvider);
    final count =
        result.matched == result.total ? songsCount(result.total) : '${result.matched} z ${result.total} skladeb';
    messenger?.showSnackBar(SnackBar(
      content: Text(
        '„${result.title}“ je v Knihovně › Sdílené ($count).'
        '${result.truncated ? ' Spotify veřejně ukazuje jen prvních 100.' : ''}',
      ),
    ));
    router.push('/playlists/${result.id}');
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    final detail = switch (e) {
      ApiException(:final detail?) => detail,
      TimeoutException() => 'Import trvá moc dlouho, zkus to za chvíli znovu.',
      _ => 'Odkaz se nepodařilo načíst.',
    };
    messenger?.showSnackBar(SnackBar(content: Text(detail)));
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
      title: const Text('Přidat z odkazu'),
      content: TextField(
        controller: controller,
        autofocus: controller.text.isEmpty,
        decoration: const InputDecoration(hintText: 'Odkaz ze Spotify nebo Apple Music'),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        GlassButton(
          label: 'Zrušit',
          style: GlassButtonStyle.plain,
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
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
