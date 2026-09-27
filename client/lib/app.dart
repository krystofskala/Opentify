import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/app_router.dart';
import 'state/audio_player_controller.dart';

const _defaultSeed = Colors.deepPurple;

class OpentifyApp extends ConsumerWidget {
  const OpentifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // "PixelPlay"-styl dynamické zabarvení: seed M3 palety appky se ladí
    // podle obalu právě hrající skladby (viz AudioPlayerController), takže
    // celé UI -- ne jen PlayerBar -- jemně odráží náladu poslouchané hudby.
    final accent = ref.watch(audioPlayerControllerProvider.select((s) => s.accentColor));
    final seed = accent ?? _defaultSeed;

    return MaterialApp.router(
      title: 'Opentify',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      routerConfig: router,
    );
  }
}
