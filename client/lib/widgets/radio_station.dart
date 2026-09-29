import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

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
  WidgetRef ref,
  RadioSeed seed,
  String id, {
  Future<bool>? openAfter,
  bool replaceTop = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.of(context);
  final api = ref.read(apiClientProvider);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
      duration: Duration(seconds: 20),
      content: Row(
        children: [
          Icon(Symbols.radio_rounded, size: 18),
          SizedBox(width: 8),
          Expanded(child: Text('Ladím rádio…')),
        ],
      ),
    ));
  try {
    final json = await api.postJson('/recommendations/radio', body: {'kind': seed.name, 'id': id});
    messenger?.hideCurrentSnackBar();
    // Z přehrávače: otevřít až po jeho zavření (viz NowPlayingSheetController.close).
    if (openAfter != null && !await openAfter) return;
    final location = '/playlists/${json['playlistId']}';
    // Z přehrávače nahradit jeho trasu (viz NowPlayingSheetController.slideDown).
    replaceTop ? router.pushReplacement(location) : router.push(location);
  } catch (e) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(_message(e))));
  }
}

String _message(Object error) {
  if (error is ApiException) {
    try {
      final detail = (jsonDecode(error.body) as Map<String, dynamic>)['detail'];
      if (detail is String && detail.isNotEmpty) return 'Rádio nejde: $detail';
    } catch (_) {}
  }
  return 'Rádio se nepodařilo naladit, zkus to znovu';
}
