import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/discography_model.dart';
import '../../models/release_model.dart';
import '../../state/providers.dart';

final discographyProvider =
    FutureProvider.autoDispose.family<DiscographyModel, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getDiscography(artistId);
});

const _releaseTypeLabels = {
  'album': 'Alba',
  'ep': 'EP',
  'single': 'Singly',
  'compilation': 'Kompilace',
};

/// Profil interpreta: základní info + kompletní diskografie
/// (`GET /catalog/artists/{id}/discography`) rozdělená podle typu vydání.
/// `DiscographyModel.artist` už nese vše potřebné pro header, takže tahle
/// obrazovka dělá jen jedno síťové volání, ne dvě.
class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({super.key, required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discography = ref.watch(discographyProvider(artistId));

    return discography.when(
      data: (data) => _ArtistBody(discography: data),
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Interpret se nepodařilo načíst: $error')),
      ),
    );
  }
}

class _ArtistBody extends StatelessWidget {
  const _ArtistBody({required this.discography});
  final DiscographyModel discography;

  @override
  Widget build(BuildContext context) {
    final artist = discography.artist;
    final grouped = discography.groupedByType;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
        SliverAppBar(
          expandedHeight: 220,
          pinned: true,
          flexibleSpace: FlexibleSpaceBar(
            title: Text(artist.name),
            background: artist.coverImageUrl != null
                ? Image.network(artist.coverImageUrl!, fit: BoxFit.cover, color: Colors.black26, colorBlendMode: BlendMode.darken)
                : Container(color: Theme.of(context).colorScheme.primaryContainer),
          ),
        ),
        if (grouped.isEmpty)
          const SliverFillRemaining(
            child: Center(child: Text('Pro tohoto interpreta zatím nemáme žádná vydání.')),
          )
        else
          for (final entry in grouped.entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: Text(
                  _releaseTypeLabels[entry.key] ?? entry.key,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _ReleaseRow(releases: entry.value)),
          ],
        ],
      ),
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({required this.releases});
  final List<ReleaseModel> releases;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: releases.length,
        itemBuilder: (context, index) {
          final release = releases[index];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 130,
              child: InkWell(
                onTap: () => context.push('/releases/${release.id}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: release.coverImageUrl != null
                            ? Image.network(release.coverImageUrl!, fit: BoxFit.cover)
                            : Container(color: Theme.of(context).colorScheme.surfaceVariant, child: const Icon(Icons.album)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(release.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(release.yearLabel, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
