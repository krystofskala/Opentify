import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/release/release_screen.dart' show releaseProvider;
import '../state/audio_player_controller.dart';
import '../state/library_scope.dart' show libraryIdsProvider;
import '../state/providers.dart';
import 'remove_from_library.dart' show libraryRevisionProvider;
import 'toast.dart';
import 'state_views.dart';

/// "Špatné audio": stažený soubor je jiná verze/píseň -- zdroj se zapamatuje
/// jako odmítnutý a skladba se stáhne znovu (přísně podle názvu a verze;
/// když jinde není, radši zůstane nestažená).
Future<void> reportWrongAudio(
  ProviderContainer container,
  ScaffoldMessengerState? messenger, {
  required String recordingId,
  required String title,
}) async {
  try {
    await container.read(apiClientProvider).postJson('/library/tracks/$recordingId/wrong-version');
    container.invalidate(libraryIdsProvider);
    container.read(libraryRevisionProvider.notifier).state++;
    showToast(messenger, 'Hledám správnou verzi „$title“');
    final player = container.read(audioPlayerControllerProvider.notifier);
    if (container.read(audioPlayerControllerProvider).nowPlaying?.recordingId == recordingId) {
      await player.retryCurrent();
    }
  } catch (e) {
    showToast(messenger, 'Nahlášení se nepovedlo: ${humanError(e)}');
  }
}

/// "Špatný obal": současný obrázek alba se zapamatuje jako špatný a hledá se
/// jiný; nenajde-li se, album má neutrální obal.
Future<void> reportWrongCover(
  ProviderContainer container,
  ScaffoldMessengerState? messenger, {
  required String releaseId,
}) async {
  try {
    final res = await container.read(apiClientProvider).postJson('/catalog/releases/$releaseId/wrong-cover');
    container.invalidate(releaseProvider(releaseId));
    showToast(messenger, res['found'] == true ? 'Obal vyměněn' : 'Jiný obal jsem nenašel – album má zatím neutrální');
  } catch (e) {
    showToast(messenger, 'Nahlášení se nepovedlo: ${humanError(e)}');
  }
}
