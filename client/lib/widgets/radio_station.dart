import 'toast.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../state/providers.dart';

/// Druh semínka pro "Přejít na rádio".
enum RadioSeed { track, album, playlist, artist }

/// "Přejít na rádio" (jako Spotify): server složí playlist podobné hudby
/// podle skladby/alba/playlistu/interpreta (backend app/home/radio_station.py)
/// a otevře se. Kontext (navigace, toasty) se bere hned na začátku --
/// volající (menu, sheet) se mezitím může zavřít.
Future<void> goToRadio(
  BuildContext context,
  RadioSeed seed,
  String id, {
  Future<bool>? openAfter,
  bool replaceTop = false,
}) async {
  // Pojistka: rádio se ladí pár sekund -- další klepnutí ho nesmí spustit
  // znovu (audit UI: opakované klepnutí trefovalo i sousední akce).
  if (_tuning) return;
  _tuning = true;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.of(context);
  // Kontejner appky, ne `ref` volajícího -- volá se i ze zavíraného menu,
  // jehož `ref` už neplatí.
  final api = ProviderScope.containerOf(context, listen: false).read(apiClientProvider);
  showToast(messenger, 'Ladím rádio…', duration: const Duration(seconds: 20));
  try {
    final json = await api.postJson('/recommendations/radio', body: {'kind': seed.name, 'id': id});
    messenger?.hideCurrentSnackBar();
    // Z přehrávače: otevřít až po jeho zavření (viz NowPlayingSheetController.close).
    if (openAfter != null && !await openAfter) return;
    final location = '/playlists/${json['playlistId']}';
    // Z přehrávače nahradit jeho trasu (viz NowPlayingSheetController.slideDown).
    replaceTop ? router.pushReplacement(location) : router.push(location);
  } catch (e) {
    showToast(messenger, _message(e));
  } finally {
    _tuning = false;
  }
}

bool _tuning = false;

String _message(Object error) {
  if (error is ApiException) {
    try {
      final detail = (jsonDecode(error.body) as Map<String, dynamic>)['detail'];
      if (detail is String && detail.isNotEmpty) return 'Rádio nejde: $detail';
    } catch (_) {}
  }
  return 'Rádio se nepodařilo naladit, zkus to znovu';
}
