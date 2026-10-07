import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../widgets/toast.dart';
import 'spoken_data.dart';

/// Srdíčko celé knihy nebo autora / interpreta (kapitola srdíčko nemá).
/// Kniha se srdíčkem je mezi "mými" (Tvoje knihy, Knihovna › Moje).
class SpokenHeart extends ConsumerWidget {
  const SpokenHeart({super.key, this.bookId, this.person, this.narrator = false, this.size = 24, this.color});

  final String? bookId;
  final String? person;
  final bool narrator;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favs = ref.watch(spokenFavoritesProvider).valueOrNull;
    final on = favs != null &&
        (bookId != null ? favs.books.contains(bookId) : favs.people.contains(spokenPersonRef(person ?? '', narrator: narrator)));
    final label = bookId != null
        ? (on ? 'Odebrat z mých knih' : 'Uložit do mých knih')
        : (on ? 'Odebrat z oblíbených' : (narrator ? 'Oblíbený interpret' : 'Oblíbený autor'));
    return IconButton(
      tooltip: label,
      icon: Icon(Symbols.favorite_rounded, fill: on ? 1 : 0, size: size, semanticLabel: label),
      color: on ? Theme.of(context).colorScheme.error : color,
      onPressed: favs == null
          ? null
          : () async {
              try {
                await setSpokenFavorite(ref, bookId: bookId, person: person, narrator: narrator, on: !on);
                if (context.mounted && bookId != null) toast(context, on ? 'Odebráno z mých knih' : 'Uloženo do mých knih');
              } catch (_) {
                if (context.mounted) toast(context, 'Nepodařilo se uložit');
              }
            },
    );
  }
}
