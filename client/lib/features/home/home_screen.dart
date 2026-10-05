import 'dart:math' as math;

import '../browse/browse_category_screen.dart' show DeezerPlaylistTile;
import '../browse/tag_screen.dart' show TagChips, tagRoute;
import 'package:flutter/material.dart';
import '../../widgets/artist_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/listen_later_screen.dart' show ListenLaterReminder;
import 'package:material_symbols_icons/symbols.dart';

import '../../data/browse_repository.dart' show BrowseArtist;
import '../../data/home_repository.dart';
import '../../data/play_now_repository.dart' show PlayNowMood;
import '../../state/auto_continue.dart';
import '../../widgets/toast.dart' show showToast;
import '../../models/availability.dart';
import '../../models/recording_model.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart';
import '../../widgets/mix_artwork.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';
import '../../state/audio_player_controller.dart' show audioPlayerControllerProvider;
import '../../widgets/track_actions.dart' show nowPlayingInfoFor, showTrackActionsSheet;
import '../../widgets/collection_actions.dart';
import '../blend/blend_screen.dart' show BlendInviteBanner;
import '../browse/browse_grid.dart' show BrowseTile;

/// Domů -- celá obrazovka z `GET /home` (žebříčky, mixy, nová a populární
/// alba, žánry, nálady), sekce se vykreslují podle `type`. Prázdné sekce
/// server vůbec nepošle.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  String _greeting() {
    final hour = DateTime.now().hour;
    // "Dobrou noc" se v češtině říká na rozloučenou, ne na pozdrav.
    if (hour < 5) return 'Dobrý večer';
    if (hour < 10) return 'Dobré ráno';
    if (hour < 18) return 'Dobrý den';
    return 'Dobrý večer';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    final recent = ref.watch(recentContextsProvider).valueOrNull ?? const <RecentContext>[];

    return Scaffold(
      // Úprava sekcí jen v Profil › Domů (na Domů žádná ikona navíc).
      appBar: SectionAppBar(_greeting()),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(homeProvider);
          ref.invalidate(recentContextsProvider);
          try {
            await ref.read(homeProvider.future);
          } catch (_) {}
        },
        child: home.when(
          data: (sections) => ListView(
            padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
            children: [
              // "Pokračovat v poslechu" posílá server vždy (jako zástupce) --
              // prázdný Domů = nic jiného než ten, a ještě bez historie.
              if (sections.every((s) => s.type == HomeSectionType.continueListening) && recent.isEmpty)
                const EmptyState(
                  icon: Symbols.home_rounded,
                  message: 'Tady zatím nic není. Najdi si hudbu v Hledat – z toho, co posloucháš, se Domů poskládá '
                      'samo. Sekce si zapneš v Profil › Domů.',
                ),
              // Pozvánka do společného mixu (Blend), čeká na mě.
              const BlendInviteBanner(),
              // Něco, co v "Poslechnout později" leží přes 2 týdny.
              const ListenLaterReminder(),
              // Pořadí a skrytí sekcí podle profilu (Domů › Upravit); "Pokračovat
              // v poslechu" je mezi nimi jako zástupce (data z /home/recent).
              for (final section in sections)
                if (section.type == HomeSectionType.continueListening)
                  if (recent.isNotEmpty) _ContinueListening(items: recent) else const SizedBox.shrink()
                else
                  _HomeSectionView(section: section),
            ],
          ),
          loading: () => const _HomeSkeleton(),
          error: (error, stack) => ListView(
            children: [
              ErrorState(
                message: 'Domů se nepodařilo načíst.',
                error: error,
                onRetry: () => ref.invalidate(homeProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Pokračovat v poslechu" -- mřížka kompaktních dlaždic (obal + název +
/// interpret) jako Spotify nahoře na Domů. Ze serveru (`/home/recent`),
/// takže přežije obnovení stránky i jiné zařízení.
class _ContinueListening extends ConsumerWidget {
  const _ContinueListening({required this.items});
  final List<RecentContext> items;

  /// Skladba bez alba jako `RecordingModel` -- pro přehrání a menu skladby.
  static RecordingModel _recording(RecentContext item) => RecordingModel(
        id: item.id,
        title: item.title,
        artistId: item.artistId,
        artistName: item.artistName,
        availability: Availability.available,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Pokračovat v poslechu'),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gap = AppSpacing.xs;
              // Stejné sloupce jako Rychlý výběr pod tím -- okraje dlaždic
              // pod sebou lícují (design audit #8).
              final columns = constraints.maxWidth >= 720 ? 3 : 2;
              final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
              final shape = AppShapes.of(Expressive.cornerMedium);
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final item in items.take(6))
                    SizedBox(
                      width: width,
                      height: 56,
                      child: GlassPressable(
                        shape: shape,
                        minSize: Size.zero,
                        // Dlouhý stisk: přehrát jako další / do fronty (alba a playlisty).
                        onLongPress: switch (item.kind) {
                          'album' => () => showCollectionActions(context,
                              kind: CollectionKind.album,
                              id: item.id,
                              title: item.title,
                              subtitle: item.artistName,
                              imageUrl: item.imageUrl),
                          'playlist' => () => showCollectionActions(context,
                              kind: CollectionKind.playlist,
                              id: item.id,
                              title: item.title,
                              imageUrl: item.imageUrls.firstOrNull),
                          'liked' => () => showCollectionActions(context,
                              kind: CollectionKind.liked, id: item.id, title: item.title),
                          'artist' => () =>
                              showArtistActions(context, id: item.id, name: item.title, imageUrl: item.imageUrl),
                          // Skladba: stejné menu jako kdekoli jinde.
                          'track' => () =>
                              showTrackActionsSheet(context, recording: _recording(item), artworkUrl: item.imageUrl),
                          _ => null,
                        },
                        onPressed: () => switch (item.kind) {
                          'album' => context.push('/releases/${item.id}'),
                          'playlist' => context.push('/playlists/${item.id}'),
                          'liked' => context.push('/library/liked'),
                          'artist' => context.push('/artists/${item.id}'),
                          // Skladbu pustit (dřív vedla na interpreta -- nečekané).
                          'track' => ref
                              .read(audioPlayerControllerProvider.notifier)
                              .playTrack(nowPlayingInfoFor(_recording(item), artworkUrl: item.imageUrl)),
                          _ => item.artistId != null ? context.push('/artists/${item.artistId}') : null,
                        },
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            shape: shape,
                            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.72),
                          ),
                          child: ClipPath(
                            clipper: ShapeBorderClipper(shape: shape),
                            child: Row(
                              children: [
                                SizedBox(width: 56, height: 56, child: _recentArtwork(context, item)),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelLarge?.copyWith(
                                          color: theme.colorScheme.onSecondaryContainer,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (item.artistName != null)
                                        Text(
                                          item.artistName!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.75),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

Widget _recentArtwork(BuildContext context, RecentContext item) {
  switch (item.kind) {
    case 'playlist':
      // Vlastní mixy stejným generativním obalem jako na kartě a v
      // hlavičce -- dřív tu byla mozaika fotek (design audit #1).
      return PlaylistArtwork(
        title: item.title,
        coverUrls: item.imageUrls,
        showTitle: false,
        dailyMixNumber: item.dailyMixNumber,
        mix: mixArtForSource(
          source: item.source,
          title: item.title,
          photos: item.imageUrls,
          color: mixHex(item.accentColor),
          categoryGroup: item.artStyle == 'mood' ? 'mood' : null,
        ),
      );
    case 'liked':
      final scheme = Theme.of(context).colorScheme;
      return ColoredBox(
        color: scheme.primaryContainer,
        child: Icon(Symbols.favorite_rounded, fill: 1, color: scheme.onPrimaryContainer),
      );
    case 'artist':
      return Padding(
        padding: const EdgeInsets.all(4),
        child: ClipOval(child: ArtworkImage(url: item.imageUrl, icon: Symbols.person_rounded)),
      );
    default:
      return ArtworkImage(url: item.imageUrl, icon: Symbols.album_rounded);
  }
}

class _HomeSectionView extends StatelessWidget {
  const _HomeSectionView({required this.section});
  final HomeSection section;

  @override
  Widget build(BuildContext context) {
    switch (section.type) {
      case HomeSectionType.quickPicks:
        // Vlastní nadpis -- bez něj splýval s "Pokračovat v poslechu" nad ním
        // (stejné kompaktní dlaždice, živě nahlášeno).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [SectionHeader(section.title), _QuickPicks(cards: section.playlists)],
        );
      case HomeSectionType.playlistCards:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.playlists.length > 3
                  ? () => _showPlaylistGrid(context, section.title, section.playlists)
                  : null,
              // "Tvoje roky" -> Wrapped (statistiky a sdílecí obrázky).
              trailing: section.id == 'years'
                  ? TextButton.icon(
                      onPressed: () => context.push('/wrapped'),
                      icon: const Icon(Symbols.equalizer_rounded, size: 18),
                      label: const Text('Wrapped'),
                    )
                  : null,
            ),
            SizedBox(
              height: 214,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.playlists.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final card = section.playlists[index];
                  return PlaylistCardView(
                    card: card,
                    onTap: () => context.push('/playlists/${card.id}'),
                    onLongPress: () => _playlistActions(context, card),
                  );
                },
              ),
            ),
          ],
        );
      case HomeSectionType.albumCards:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.albums.length > 3 ? () => _showAlbumGrid(context, section.title, section.albums) : null,
            ),
            SizedBox(
              height: 204,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.albums.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) =>
                    SizedBox(width: 150, child: _albumCard(context, section.albums[index], index)),
              ),
            ),
          ],
        );
      case HomeSectionType.trackRail:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.playlistId != null ? () => context.push('/playlists/${section.playlistId}') : null,
              trailing: _PlayAllButton(recordings: section.tracks, sourceLabel: section.title),
            ),
            _TrackColumns(recordings: section.tracks, sourceLabel: section.title),
          ],
        );
      case HomeSectionType.tagChips:
        // Tvé styly (štítky Last.fm tvých interpretů) -> stránky stylů.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(section.title),
            TagChips(tags: [for (final t in section.tags) t.tag], titles: [for (final t in section.tags) t.title]),
          ],
        );
      case HomeSectionType.artistCards:
        void artistMenu(BrowseArtist a) =>
            showArtistActions(context, id: a.id, name: a.name, imageUrl: a.images.isEmpty ? null : a.images.first);
        Widget artistTile(BuildContext sheet, int index) {
          final a = section.artists[index];
          return MediaCard(
            title: a.name,
            imageUrl: a.images.isEmpty ? null : a.images.first,
            shape: MediaCardShape.circle,
            placeholderIcon: Symbols.person_rounded,
            artworkKey: (releaseId: null, artistId: a.id),
            onTap: _closeThen(sheet, () => context.push('/artists/${a.id}')),
            onLongPress: _closeThen(sheet, () => artistMenu(a)),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.artists.length > 3
                  ? () => _showGrid(context, section.title, section.artists.length, artistTile, 0.78)
                  : null,
            ),
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.artists.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final a = section.artists[index];
                  return SizedBox(
                    width: 130,
                    child: MediaCard(
                      title: a.name,
                      imageUrl: a.images.isEmpty ? null : a.images.first,
                      shape: MediaCardShape.circle,
                      placeholderIcon: Symbols.person_rounded,
                      artworkKey: (releaseId: null, artistId: a.id),
                      onTap: () => context.push('/artists/${a.id}'),
                      onLongPress: () => artistMenu(a),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      case HomeSectionType.deezerPlaylists:
        // Populární playlisty pro tvé styly (Deezer) -- převezmou se až na klepnutí.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.deezerPlaylists.length > 3
                  ? () => _showGrid(
                      context,
                      section.title,
                      section.deezerPlaylists.length,
                      (sheet, i) => DeezerPlaylistTile(
                            playlist: section.deezerPlaylists[i],
                            onBeforeOpen: () => Navigator.of(sheet).pop(),
                          ),
                      0.72)
                  : null,
            ),
            SizedBox(
              height: 214,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.deezerPlaylists.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) =>
                    SizedBox(width: 150, child: DeezerPlaylistTile(playlist: section.deezerPlaylists[index])),
              ),
            ),
          ],
        );
      case HomeSectionType.genreShowcase:
        // `sheet` = v mřížce "Zobrazit vše" (nejdřív zavřít, pak otevřít).
        Widget showcaseTile(ShowcaseItem item, {BuildContext? sheet}) {
          if (item.playlist case final card?) {
            return PlaylistCardView(
              card: card,
              onTap: _closeThen(sheet, () => context.push('/playlists/${card.id}')),
              onLongPress: _closeThen(sheet, () => _playlistActions(context, card)),
            );
          }
          if (item.album case final album?) {
            return SizedBox(
              width: 150,
              child: Stack(
                children: [
                  _albumCard(context, album, null, sheet: sheet),
                  if (item.badge != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: const StadiumBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          child: Text(
                            item.badge!,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: Theme.of(context).colorScheme.onPrimary),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          }
          return SizedBox(
            width: 140,
            child: MediaCard(
              title: item.artistName ?? '',
              subtitle: 'Interpret',
              imageUrl: item.artistImage,
              shape: MediaCardShape.circle,
              placeholderIcon: Symbols.person_rounded,
              artworkKey: (releaseId: null, artistId: item.artistId),
              onTap: _closeThen(sheet, () => context.push('/artists/${item.artistId}')),
              onLongPress: item.artistId == null
                  ? null
                  : _closeThen(
                      sheet,
                      () => showArtistActions(context,
                          id: item.artistId!, name: item.artistName ?? '', imageUrl: item.artistImage)),
            ),
          );
        }
        // Ukázka stránky žánru: mix napřed, pak novinky, alba a interpreti.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: section.categoryId != null
                  ? () => context.push('/browse/${section.categoryId}')
                  : (section.tag != null
                      ? () => context.push(tagRoute(section.tag!))
                      // Bez vlastní stránky (Tvoje výběry): celá řada v mřížce.
                      : (section.showcase.length > 3
                          ? () => _showGrid(context, section.title, section.showcase.length,
                              (sheet, i) => showcaseTile(section.showcase[i], sheet: sheet), 0.72)
                          : null)),
            ),
            SizedBox(
              height: 214,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.showcase.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (_, index) => showcaseTile(section.showcase[index]),
              ),
            ),
          ],
        );
      case HomeSectionType.categoryTiles:
        // Stejné dlaždice jako v Hledat (BrowseTile), ne karty playlistů.
        const tileWidth = 168.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              section.title,
              onSeeAll: () => _showGrid(
                context,
                section.title,
                section.categories.length,
                (sheet, index) => BrowseTile(
                  category: section.categories[index],
                  onBeforeOpen: () => Navigator.of(sheet).pop(),
                ),
                1.75,
              ),
            ),
            SizedBox(
              height: tileWidth / 1.75,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: section.categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) =>
                    SizedBox(width: tileWidth, child: BrowseTile(category: section.categories[index])),
              ),
            ),
          ],
        );
      case HomeSectionType.continueListening: // vykresluje HomeScreen (data z /home/recent)
      case HomeSectionType.unknown:
        return const SizedBox.shrink();
    }
  }
}

/// `sheet` = karta v mřížce "Zobrazit vše": nejdřív sheet zavřít, jinak se
/// album otevřelo POD ním.
Widget _albumCard(BuildContext context, HomeAlbumCard album, int? index, {BuildContext? sheet}) => MediaCard(
      title: album.title,
      // Poznámka sekce ("30 let", "zbývá 6 skladeb") za interpretem.
      subtitle:
          album.badge == null ? album.artistName : [album.artistName, album.badge].whereType<String>().join(' · '),
      imageUrl: album.images.isEmpty ? null : album.images.first,
      artworkKey: (releaseId: album.id, artistId: album.artistId),
      onTap: _closeThen(sheet, () => context.push('/releases/${album.id}')),
      onLongPress: _closeThen(
        sheet,
        () => showCollectionActions(
          context,
          kind: CollectionKind.album,
          id: album.id,
          title: album.title,
          subtitle: album.artistName,
          imageUrl: album.images.isEmpty ? null : album.images.first,
          // Přejít na interpreta + jméno do sdílení; "v knihovně" dopočítá menu.
          artistId: album.artistId,
          artistName: album.artistName,
        ),
      ),
      animationIndex: index == null ? null : index % 8,
    );

/// Akce z karty v mřížce "Zobrazit vše": nejdřív zavřít sheet, pak akce na
/// stránce pod ním. Bez `sheet` (karta na Domů) rovnou akce.
VoidCallback _closeThen(BuildContext? sheet, VoidCallback action) => () {
      if (sheet != null) Navigator.of(sheet).pop();
      action();
    };

void _playlistActions(BuildContext context, HomePlaylistCard card) => showCollectionActions(
      context,
      kind: CollectionKind.playlist,
      id: card.id,
      title: card.title,
      subtitle: card.description,
      imageUrl: card.coverUrls.firstOrNull,
    );

/// Rychlý výběr -- 2 sloupce kompaktních dlaždic.
class _QuickPicks extends ConsumerWidget {
  const _QuickPicks({required this.cards});
  final List<HomePlaylistCard> cards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = AppSpacing.xs;
          final columns = constraints.maxWidth >= 720 ? 3 : 2;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          // Pusť teď je navíc -> mřížka bez díry na konci (ubere se poslední).
          final total = cards.length + 1;
          final fit = total < columns ? total : total - total % columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(width: width, height: 56, child: const _PlayNowTile()),
              for (final card in cards.take(fit - 1))
                SizedBox(
                  width: width,
                  height: 56,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: QuickPickTile(
                          card: card,
                          onTap: () => context.push('/playlists/${card.id}'),
                          onLongPress: () => _playlistActions(context, card),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// První dlaždice Rychlého výběru: klepnutí = hudba na teď (nekonečná,
/// doplňuje se sama), dlouhý stisk = nálada.
class _PlayNowTile extends ConsumerStatefulWidget {
  const _PlayNowTile();

  @override
  ConsumerState<_PlayNowTile> createState() => _PlayNowTileState();
}

class _PlayNowTileState extends ConsumerState<_PlayNowTile> {
  bool _loading = false;

  Future<void> _start({String? mood}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _loading = true);
    try {
      final reason = await ref.read(autoContinueProvider).start(mood: mood);
      if (reason != null && reason.isNotEmpty) showToast(messenger, reason);
    } catch (e) {
      showToast(messenger, 'Pusť teď se nepovedlo: ${humanError(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickMood() async {
    final moods = ref.read(playNowRepositoryProvider).moods();
    final picked = await showGlassSheet<String>(
      context,
      builder: (sheet) => GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pusť teď – na jakou náladu?', style: Theme.of(sheet).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              FutureBuilder<List<PlayNowMood>>(
                future: moods,
                builder: (context, snap) {
                  if (snap.hasError) return Text(humanError(snap.error!));
                  if (!snap.hasData) {
                    return const Center(child: Padding(padding: EdgeInsets.all(AppSpacing.md), child: CircularProgressIndicator()));
                  }
                  return Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final m in snap.data!)
                        ActionChip(label: Text(m.title), onPressed: () => Navigator.of(sheet).pop(m.id)),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _start(mood: picked);
  }

  @override
  Widget build(BuildContext context) => PlayNowTile(loading: _loading, onTap: _start, onLongPress: _pickMood);
}

/// Sekce, která je jen seznam skladeb ("Mix na teď", "Před rokem",
/// SoundCloud...): sloupce po 4 řádcích, listují se do strany po celých
/// sloupcích -- jako seznam, ne karusel obalů (ten patří albům a playlistům).
class _TrackColumns extends StatelessWidget {
  const _TrackColumns({required this.recordings, required this.sourceLabel});
  final List<RecordingModel> recordings;
  final String sourceLabel;

  static const int _perColumn = 4;
  static const double _rowHeight = 64;

  @override
  Widget build(BuildContext context) {
    final columns = <List<int>>[];
    for (var i = 0; i < recordings.length; i += _perColumn) {
      columns.add([for (var j = i; j < math.min(i + _perColumn, recordings.length); j++) j]);
    }
    final rows = math.min(_perColumn, recordings.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Další sloupec vykukuje -- je vidět, že se dá listovat.
        final width = math.min(constraints.maxWidth - AppSpacing.md * 2 - 28, 420.0);
        return SizedBox(
          height: rows * _rowHeight + AppSpacing.xs,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
            itemCount: columns.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, c) => SizedBox(
              width: width,
              child: Column(
                children: [
                  for (final i in columns[c])
                    SizedBox(
                      height: _rowHeight,
                      child: TrackTile(
                        recording: recordings[i],
                        subtitle: recordings[i].artistName,
                        queueRecordings: recordings,
                        sourceLabel: sourceLabel,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "Přehrát" v záhlaví seznamu skladeb -- celý seznam od začátku.
class _PlayAllButton extends ConsumerWidget {
  const _PlayAllButton({required this.recordings, required this.sourceLabel});
  final List<RecordingModel> recordings;
  final String sourceLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
        tooltip: 'Přehrát',
        icon: const Icon(Symbols.play_circle_rounded, fill: 1),
        onPressed: recordings.isEmpty
            ? null
            : () => ref
                .read(audioPlayerControllerProvider.notifier)
                .playQueue([for (final r in recordings) nowPlayingInfoFor(r)], 0, sourceLabel: sourceLabel),
      );
}

/// "Zobrazit vše" -- mřížka ve skleněném sheetu (překryv = sklo).
Future<void> _showGrid(
    BuildContext context, String title, int count, Widget Function(BuildContext, int) itemBuilder, double aspect) {
  return showGlassSheet(
    context,
    // Stejné rozměry, úchyt i nadpis jako sheet se skladbami (TrackListSheet).
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => GlassSheet(
        expand: true,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverToBoxAdapter(child: SectionHeader(title)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  childAspectRatio: aspect,
                  crossAxisSpacing: AppSpacing.sm,
                  mainAxisSpacing: AppSpacing.sm,
                ),
                itemCount: count,
                itemBuilder: itemBuilder,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showPlaylistGrid(BuildContext context, String title, List<HomePlaylistCard> cards) => _showGrid(
      context,
      title,
      cards.length,
      (sheet, index) => LayoutBuilder(
        builder: (_, c) => PlaylistCardView(
          card: cards[index],
          width: c.maxWidth,
          onTap: _closeThen(sheet, () => context.push('/playlists/${cards[index].id}')),
          onLongPress: _closeThen(sheet, () => _playlistActions(context, cards[index])),
        ),
      ),
      0.72,
    );

// Stejná karta jako v řadě na Domů (obal z artworkKey, menu, poznámka).
Future<void> _showAlbumGrid(BuildContext context, String title, List<HomeAlbumCard> albums) => _showGrid(
      context,
      title,
      albums.length,
      (sheet, index) => _albumCard(context, albums[index], null, sheet: sheet),
      0.74,
    );

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (var i = 0; i < 6; i++)
                LayoutBuilder(
                  builder: (context, _) => SkeletonBox(
                    width: (MediaQuery.sizeOf(context).width - AppSpacing.md * 2 - AppSpacing.xs) / 2,
                    height: 56,
                    radius: AppRadii.md,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          for (var i = 0; i < 3; i++) ...[
            // Align: v ListView by se box roztáhl přes celou šířku.
            const Align(alignment: Alignment.centerLeft, child: SkeletonBox(width: 140, height: 20)),
            const SizedBox(height: AppSpacing.sm),
            const SkeletonCardRail(height: 190, cardWidth: 150),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      );
}
