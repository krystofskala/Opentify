import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/availability.dart';
import '../../models/search_result.dart';
import '../../state/playback_controller.dart';
import '../../state/provisioning_controller.dart';
import '../../state/providers.dart';
import '../../widgets/availability_badge.dart';

/// Aktuální dotaz do vyhledávání -- text pole ho aktualizuje s debounce,
/// `searchResultsProvider` na něj reaguje a strhne nový `/catalog/search`.
final searchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

final searchResultsProvider = FutureProvider.autoDispose<CatalogSearchResult?>((ref) async {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) return null;
  return ref.watch(catalogRepositoryProvider).search(query);
});

/// Hlavní "proklikávací" obrazovka: vyhledávací pole s živým výsledkem přes
/// `/catalog/search`, vizuální odlišení `available`/`provisionable` a klik
/// routuje dál -- interpret na jeho profil, album na tracklist, skladba se
/// rovnou provisionuje/přehraje na místě.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  static const _debounceDuration = Duration(milliseconds: 350);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      ref.read(searchQueryProvider.notifier).state = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider);
    final query = ref.watch(searchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Interpret, album nebo skladba…',
            border: InputBorder.none,
          ),
        ),
      ),
      body: switch (query.trim().isEmpty) {
        true => const Center(child: Text('Začni psát pro vyhledávání v globálním katalogu.')),
        false => results.when(
            data: (data) {
              final items = data?.results ?? const [];
              if (items.isEmpty) return const Center(child: Text('Nic nenalezeno.'));
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) => _SearchResultRow(item: items[index]),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Center(child: Text('Chyba vyhledávání: $error')),
          ),
      },
    );
  }
}

class _SearchResultRow extends ConsumerWidget {
  const _SearchResultRow({required this.item});

  final SearchResultItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leadingIcon = switch (item.entityType) {
      SearchEntityType.artist => Icons.person,
      SearchEntityType.release => Icons.album,
      SearchEntityType.recording => Icons.music_note,
    };

    return ListTile(
      leading: item.imageUrl != null
          ? CircleAvatar(backgroundImage: NetworkImage(item.imageUrl!))
          : CircleAvatar(child: Icon(leadingIcon)),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: item.subtitle == null ? null : Text(item.subtitle!),
      trailing: item.availability == null ? null : AvailabilityBadge(availability: item.availability!),
      onTap: () => _onTap(context, ref),
    );
  }

  void _onTap(BuildContext context, WidgetRef ref) {
    switch (item.entityType) {
      case SearchEntityType.artist:
        context.push('/artists/${item.id}');
      case SearchEntityType.release:
        context.push('/releases/${item.id}');
      case SearchEntityType.recording:
        // Skladby nemají vlastní detailní obrazovku -- klik ji buď rovnou
        // přehraje (available), nebo spustí on-demand provisioning.
        if (item.availability == Availability.available) {
          ref.read(playbackControllerProvider.notifier).play(item.id);
        } else {
          ref.read(provisioningControllerProvider.notifier).provision(item.id);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Obstarávání skladby spuštěno…')),
          );
        }
    }
  }
}
