import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/liked_songs_controller.dart';

/// Srdíčko skladby všude v appce:
///   - klepnutí = do/z Oblíbených (u zlomeného srdce ho spraví a dá do
///     Oblíbených),
///   - dlouhé podržení = zlomené srdce ("nelíbí se mi" -- skladba zmizí
///     z Oblíbených i z výběrů (mixy, rádia), ListenBrainz "hate"),
///     další dlouhé podržení ho zase spraví.
class LikeHeart extends ConsumerWidget {
  const LikeHeart({super.key, required this.recordingId, this.size = 24, this.color});

  final String recordingId;
  final double size;

  /// Barva prázdného/zlomeného srdce (přehrávač bílá); výchozí z motivu.
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(recordingId) ?? false));
    final disliked = ref.watch(dislikedProvider.select((s) => s.contains(recordingId)));
    final base = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final (icon, fill, tint, label) = disliked
        ? (Symbols.heart_broken_rounded, 1.0, base.withValues(alpha: 0.75), 'Nelíbí se mi -- podrž pro zrušení')
        : liked
            ? (Symbols.favorite_rounded, 1.0, Colors.redAccent, 'Odebrat z oblíbených')
            : (Symbols.favorite_border_rounded, 0.0, base, 'Přidat do oblíbených (podrž = nelíbí se mi)');
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          HapticFeedback.selectionClick();
          final messenger = ScaffoldMessenger.maybeOf(context);
          // Server lajkem zlomené srdce sám spraví -- tady jen místně.
          if (disliked) ref.read(dislikedProvider.notifier).forget(recordingId);
          final ok = await ref.read(likedSongsControllerProvider.notifier).setLiked(recordingId, disliked || !liked);
          if (!ok && disliked) ref.read(dislikedProvider.notifier).restore(recordingId);
          if (!ok) messenger?.showSnackBar(const SnackBar(content: Text('Oblíbené se nepodařilo uložit.')));
        },
        onLongPress: () async {
          HapticFeedback.mediumImpact();
          final messenger = ScaffoldMessenger.maybeOf(context);
          final ok = await ref.read(dislikedProvider.notifier).toggle(recordingId);
          if (!ok) messenger?.showSnackBar(const SnackBar(content: Text('Nepodařilo se uložit.')));
        },
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutBack,
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
              child: Icon(icon, key: ValueKey(icon), size: size, fill: fill, color: tint),
            ),
          ),
        ),
      ),
    );
  }
}
