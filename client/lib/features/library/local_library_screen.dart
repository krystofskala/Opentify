import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/recording_model.dart';
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/recording_tile.dart';

const _pageSize = 100;

final _localAlbumsProvider = FutureProvider.autoDispose((ref) => ref.watch(libraryRepositoryProvider).localAlbums());
final _localArtistsProvider = FutureProvider.autoDispose((ref) => ref.watch(libraryRepositoryProvider).localArtists());

/// Naskenovaná lokální knihovna (`POST /library/scan`, viz Profil), ve
/// stylu PixelPlayeru (github.com/brendmung/PixelPlayer): pilulkové taby
/// Skladby/Alba/Interpreti místo jednoho plochého seznamu -- na 1000+
/// souborech je to jediný způsob, jak se v knihovně dá rozumně orientovat.
/// Karty alb/interpretů vedou rovnou na existující Release/Artist obrazovky,
/// žádná duplicitní detailní obrazovka navíc.
class LocalLibraryScreen extends StatelessWidget {
  const LocalLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Knihovna'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Skladby'),
              Tab(text: 'Alba'),
              Tab(text: 'Interpreti'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_SongsTab(), _AlbumsTab(), _ArtistsTab()],
        ),
      ),
    );
  }
}

/// Kolik sloupců mřížky se vejde vedle sebe -- stejný widget pak funguje na
/// mobilu (2-3 sloupce) i na širokém desktop okně (klidně 6+), bez
/// samostatné "desktop verze" navíc.
int _gridColumns(double width) => (width / 170).floor().clamp(2, 8);

class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab();

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<_SongsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final List<RecordingModel> _items = [];
  int _total = 0;
  bool _loading = false;
  bool _initialLoadDone = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final page = await ref.read(libraryRepositoryProvider).localTracks(limit: _pageSize, offset: _items.length);
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      setState(() {
        _loading = false;
        _initialLoadDone = true;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _initialLoadDone = false;
    });
    await _loadMore();
  }

  void _shufflePlay() {
    if (_items.isEmpty) return;
    final recording = _items[Random().nextInt(_items.length)];
    final streamUrl = ref.read(provisioningRepositoryProvider).streamUrl(recording.id);
    ref.read(audioPlayerControllerProvider.notifier).playTrack(
          NowPlayingInfo(recordingId: recording.id, title: recording.title),
          streamUrl,
        );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_initialLoadDone) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) return Center(child: Text('Nepodařilo se načíst: $_error'));

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _items.isEmpty ? null : _shufflePlay,
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle'),
                  ),
                  const Spacer(),
                  Text('$_total skladeb', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          if (_items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Zatím žádné lokální soubory -- spusť sken v Profilu, ať se '
                  'namapovaná knihovna (MUSIC_DIR) zaeviduje.',
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: _items.length + (_items.length < _total ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _items.length) {
                  if (!_loading) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                  }
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return RecordingTile(recording: _items[index]);
              },
            ),
        ],
      ),
    );
  }
}

class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(_localAlbumsProvider);
    return albums.when(
      data: (items) => items.isEmpty
          ? const Center(child: Text('Zatím žádná alba -- spusť sken v Profilu.'))
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(_localAlbumsProvider),
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _gridColumns(MediaQuery.of(context).size.width),
                  childAspectRatio: 0.72,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final album = items[index];
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => context.push('/releases/${album.id}'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: album.coverImageUrl != null
                                ? CachedNetworkImage(imageUrl: album.coverImageUrl!, fit: BoxFit.cover)
                                : Container(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.album, size: 32),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          '${album.artistName} · ${album.trackCount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Nepodařilo se načíst: $error')),
    );
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(_localArtistsProvider);
    return artists.when(
      data: (items) => items.isEmpty
          ? const Center(child: Text('Zatím žádní interpreti -- spusť sken v Profilu.'))
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(_localArtistsProvider),
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _gridColumns(MediaQuery.of(context).size.width),
                  childAspectRatio: 0.8,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final artist = items[index];
                  return InkWell(
                    borderRadius: BorderRadius.circular(100),
                    onTap: () => context.push('/artists/${artist.id}'),
                    child: Column(
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: ClipOval(
                            child: artist.imageUrl != null
                                ? CachedNetworkImage(imageUrl: artist.imageUrl!, fit: BoxFit.cover)
                                : Container(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.person, size: 32),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                        Text('${artist.trackCount} skladeb', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  );
                },
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Nepodařilo se načíst: $error')),
    );
  }
}
