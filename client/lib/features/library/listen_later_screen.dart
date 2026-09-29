import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';


import '../../data/listen_later_repository.dart';
import '../../models/recording_model.dart';
import '../../state/artwork_provider.dart';
import '../../state/listen_later_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/player_bar.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../state/audio_player_controller.dart';
import '../../widgets/track_actions.dart' show TrackMenuAction, nowPlayingInfoFor;
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';
import '../shazam/open_shazam_badge.dart';

const _title = 'Poslechnout později';
const _sourceLabel = 'Poslechnout později';

/// Připnutá karta v Knihovně (pod Oblíbenými) -- tónový kontejner, ne sklo.
class ListenLaterCard extends ConsumerWidget {
  const ListenLaterCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = ref.watch(listenLaterProvider).valueOrNull?.active.length;
    final shape = AppShapes.of(Expressive.cornerExtraLarge);
    return GlassPressable(
      onPressed: () => context.push('/library/later'),
      shape: shape,
      minSize: Size.zero,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.tertiaryContainer, scheme.secondaryContainer],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(shape: AppShapes.of(Expressive.cornerLarge), color: scheme.tertiary),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: Icon(Symbols.schedule_rounded, fill: 1, color: scheme.onTertiary, size: 32),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_title, style: theme.textTheme.titleLarge?.copyWith(color: scheme.onTertiaryContainer)),
                    Text(
                      count == null || count == 0 ? 'Hudba na potom' : '$count ${_items(count)} na potom',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onTertiaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Symbols.chevron_right_rounded, color: scheme.onTertiaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

String _items(int n) => n == 1
    ? 'položka'
    : n >= 2 && n <= 4
        ? 'položky'
        : 'položek';

/// Seznam "Poslechnout později": skladby (s přehráním, výběrem a přidáním
/// do playlistu), alba, interpreti a sbalitelné "Poslechnuto".
class ListenLaterScreen extends ConsumerStatefulWidget {
  const ListenLaterScreen({super.key});

  @override
  ConsumerState<ListenLaterScreen> createState() => _ListenLaterScreenState();
}

class _ListenLaterScreenState extends ConsumerState<ListenLaterScreen> {
  final _collection = TrackCollectionController();

  @override
  void initState() {
    super.initState();
    // Mohlo se mezitím něco poslechnout -- přesun do "Poslechnuto".
    Future.microtask(() => ref.read(listenLaterProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(listenLaterProvider);
    return Scaffold(
      appBar: const SectionAppBar(_title),
      bottomNavigationBar: const PlayerBar(),
      body: list.when(
        data: (data) => _body(context, data),
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Seznam se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(listenLaterProvider),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, LaterList data) {
    final tracksItems = data.active.where((i) => i.kind == LaterKind.track).toList();
    final tracks = [for (final i in tracksItems) i.track!];
    final albums = data.active.where((i) => i.kind == LaterKind.album).toList();
    final artists = data.active.where((i) => i.kind == LaterKind.artist).toList();
    final notes = {for (final i in tracksItems) i.track!.id: i};

    if (data.active.isEmpty && data.listened.isEmpty) {
      return const EmptyState(
        icon: Symbols.schedule_rounded,
        message: 'Zatím tu nic není. Přidávej přes menu skladby („Poslechnout později“), '
            'dlouhým tahem skladby doleva, nebo tlačítkem s hodinami u alba a interpreta. '
            'Co si poslechneš, přesune se samo do „Poslechnuto“ a pár skladeb odsud '
            'ti občas přimíchám do Denních mixů.',
      );
    }

    return ListenableBuilder(
      listenable: _collection,
      builder: (context, _) {
        final visible = _collection.apply(tracks);
        return CustomScrollView(
          slivers: [
            if (tracks.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Skladby')),
              SliverToBoxAdapter(
                child: TrackCollectionToolbar(
                  controller: _collection,
                  allTracks: tracks,
                  visibleTracks: visible,
                  sourceLabel: _sourceLabel,
                  removeLabel: 'Odebrat ze seznamu',
                  onRemoveSelected: (selected) async {
                    final notifier = ref.read(listenLaterProvider.notifier);
                    for (final r in selected) {
                      final item = notes[r.id];
                      if (item != null) await notifier.remove(item.id);
                    }
                  },
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                sliver: SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final r = visible[i];
                    final item = notes[r.id]!;
                    return TrackTile(
                      recording: r,
                      queueRecordings: visible,
                      sourceLabel: _sourceLabel,
                      subtitle: _subtitle(r.artistName, item.note),
                      badge: item.fromShazam ? const OpenShazamBadge() : null,
                      selectionMode: _collection.selecting,
                      selected: _collection.isSelected(r.id),
                      onSelectedChanged: (value) => _collection.toggle(r.id, value),
                      extraMenuActions: [
                        TrackMenuAction(
                          icon: Symbols.edit_note_rounded,
                          label: item.note == null ? 'Přidat poznámku' : 'Upravit poznámku',
                          onSelected: () => editLaterNote(context, ref.read(listenLaterProvider.notifier), item),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
            if (albums.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Alba')),
              SliverList.builder(
                itemCount: albums.length,
                itemBuilder: (context, i) => _LaterRow(item: albums[i]),
              ),
            ],
            if (artists.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Interpreti k prozkoumání')),
              SliverList.builder(
                itemCount: artists.length,
                itemBuilder: (context, i) => _LaterRow(item: artists[i]),
              ),
            ],
            if (data.listened.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: ExpansionTile(
                    leading: const Icon(Symbols.task_alt_rounded),
                    title: Text('Poslechnuto (${data.listened.length})'),
                    subtitle: const Text('Přesouvá se sem samo, jakmile to dohraješ'),
                    shape: const Border(),
                    children: [for (final item in data.listened) _LaterRow(item: item, listened: true)],
                  ),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl + MediaQuery.paddingOf(context).bottom)),
          ],
        );
      },
    );
  }
}

String? _subtitle(String? artist, String? note) {
  if (note == null) return artist;
  return artist == null ? '„$note“' : '$artist · „$note“';
}

/// Řádek alba / interpreta / poslechnuté položky: obrázek, název, poznámka
/// a menu (poznámka, vrátit, odebrat).
class _LaterRow extends ConsumerWidget {
  const _LaterRow({required this.item, this.listened = false});
  final LaterItem item;
  final bool listened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(listenLaterProvider.notifier);
    final (String? image, String? subtitleBase, String route, bool circle) = switch (item.kind) {
      LaterKind.album => (
          item.album!.images.firstOrNull,
          item.album!.artistName,
          '/releases/${item.album!.id}',
          false,
        ),
      LaterKind.artist => (item.artist!.imageUrl, 'Interpret', '/artists/${item.artist!.id}', true),
      LaterKind.track => (
          null,
          item.track!.artistName,
          item.track!.releaseId != null ? '/releases/${item.track!.releaseId}' : '/artists/${item.track!.artistId}',
          false,
        ),
    };
    final resolved = image ??
        ref
            .watch(recordingArtworkProvider((
              releaseId: item.kind == LaterKind.track ? item.track!.releaseId : null,
              artistId: switch (item.kind) {
                LaterKind.artist => item.artist!.id,
                LaterKind.album => item.album!.artistId,
                LaterKind.track => item.track!.artistId,
              },
            )))
            .valueOrNull;
    // Stejná geometrie jako řádky skladeb (`TrackTile`): náhled 44 px,
    // odsazení 8 + 12, mezera 12 -- náhledy pod sebou lícují (design audit #13).
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs + AppSpacing.sm),
      horizontalTitleGap: AppSpacing.sm,
      leading: SizedBox(
        width: 44,
        height: 44,
        child: circle
            ? ClipOval(child: ArtworkImage(url: resolved, icon: Symbols.person_rounded, iconSize: 22))
            : ClipPath(
                clipper: ShapeBorderClipper(shape: AppShapes.sm),
                child: ArtworkImage(url: resolved, icon: Symbols.album_rounded, iconSize: 22),
              ),
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(subtitleBase, item.note) ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => context.push(route),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Symbols.more_vert_rounded),
        onSelected: (value) {
          switch (value) {
            case 'note':
              editLaterNote(context, notifier, item);
            case 'restore':
              notifier.restore(item.id);
            case 'remove':
              notifier.remove(item.id);
          }
        },
        itemBuilder: (context) => [
          if (!listened)
            PopupMenuItem(value: 'note', child: Text(item.note == null ? 'Přidat poznámku' : 'Upravit poznámku')),
          if (listened) const PopupMenuItem(value: 'restore', child: Text('Vrátit do seznamu')),
          const PopupMenuItem(value: 'remove', child: Text('Odebrat')),
        ],
      ),
    );
  }
}

/// Připomínka na Domů: něco, co v seznamu leží přes 2 týdny.
class ListenLaterReminder extends ConsumerWidget {
  const ListenLaterReminder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(listenLaterProvider.select((s) => s.valueOrNull?.reminder));
    if (item == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Stejný recept jako dlaždice "Pokračovat v poslechu" vedle (design audit #13).
    final shape = AppShapes.of(Expressive.cornerMedium);
    final RecordingModel? track = item.track;
    final route = switch (item.kind) {
      LaterKind.album => '/releases/${item.album!.id}',
      LaterKind.artist => '/artists/${item.artist!.id}',
      LaterKind.track => '/library/later',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: GlassPressable(
        shape: shape,
        minSize: Size.zero,
        onPressed: () => context.push(route),
        child: DecoratedBox(
          decoration: ShapeDecoration(shape: shape, color: scheme.secondaryContainer.withValues(alpha: 0.72)),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                Icon(Symbols.schedule_rounded, color: scheme.onSecondaryContainer),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Čeká na poslech',
                        style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer),
                      ),
                      Text(
                        [item.title, if (track?.artistName case final a?) a, if (item.note case final n?) '„$n“']
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (track != null)
                  IconButton(
                    tooltip: 'Přehrát',
                    icon: Icon(Symbols.play_circle_rounded, fill: 1, size: 32, color: scheme.onSecondaryContainer),
                    onPressed: () => ref
                        .read(audioPlayerControllerProvider.notifier)
                        .playTrack(nowPlayingInfoFor(track), sourceLabel: _sourceLabel),
                  )
                else
                  Icon(Symbols.chevron_right_rounded, color: scheme.onSecondaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
