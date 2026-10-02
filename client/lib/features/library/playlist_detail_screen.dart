import 'package:flutter/material.dart';
import '../../widgets/collection_actions.dart' show CollectionKind, showCollectionActions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/playlist_model.dart';
import '../../widgets/mix_artwork.dart';
import '../wrapped/wrapped_launch_button.dart';
import '../../models/recording_model.dart';
import '../../state/artwork_provider.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/detail_hero.dart';
import '../../widgets/detail_scaffold_states.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';
import '../../widgets/glass/glass.dart';
import '../../core/cz_plural.dart';
import '../../widgets/toast.dart';
import '../../theme/shapes.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import '../../core/config.dart';
import '../../widgets/playlist_removal.dart';

final playlistDetailProvider = FutureProvider.autoDispose.family((ref, String playlistId) {
  return ref.watch(playlistsRepositoryProvider).get(playlistId);
});

/// Detail vlastního playlistu -- stejná hlavička jako Album/Interpret
/// (obal = obal první skladby), filtr/řazení/hromadný výběr a ruční
/// přeskládání dlouhým stiskem (jen v původním pořadí bez filtru -- nad
/// seřazeným/filtrovaným pohledem by přesun neměl jasný význam).
class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  final _collection = TrackCollectionController();

  // Lokální zrcadlo `detail.items` pro okamžitou (optimistickou) odezvu na
  // přetažení/odebrání -- synchronizuje se znovu, kdykoliv provider dodá
  // nová data a zrovna neprobíhá přetahování.
  List<RecordingModel>? _items;
  String? _syncedForPlaylistId;
  bool _reordering = false;

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = ref.watch(playlistDetailProvider(widget.playlistId));

    return playlist.when(
      data: (detail) {
        if (_items == null || _syncedForPlaylistId != widget.playlistId || !_reordering) {
          _items = List.of(detail.items);
          _syncedForPlaylistId = widget.playlistId;
        }
        return _buildBody(context, detail, _items!);
      },
      loading: () => const DetailLoadingScaffold(),
      error: (error, stack) => DetailErrorScaffold(
        message: 'Playlist se nepodařilo načíst.',
        error: error,
        onRetry: () => ref.invalidate(playlistDetailProvider(widget.playlistId)),
      ),
    );
  }

  Widget _buildBody(BuildContext context, PlaylistDetailModel detail, List<RecordingModel> items) {
    final first = items.isEmpty ? null : items.first;
    final readOnly = detail.isReadOnly;
    // Mix už připnutý do Knihovny (živě aktualizovaný)?
    final pinned = ref.watch(myPlaylistsProvider
        .select((s) => s.valueOrNull?.any((p) => p.id == detail.id && p.pinned) ?? false));
    final cover = detail.coverUrls.isNotEmpty
        ? detail.coverUrls.first
        : first == null
            ? null
            : ref.watch(recordingArtworkProvider((releaseId: first.releaseId, artistId: first.artistId))).valueOrNull;

    final mixSpec = _mixSpec(detail);
    return ScreenAccent(
      imageUrl: cover,
      // Vlastní mix: barva stránky podle generativního obalu, ne fotky
      // první skladby.
      color: mixSpec?.accent,
      builder: (context, accent) => Scaffold(
        bottomNavigationBar: const PlayerBar(),
        body: CustomScrollView(
          slivers: [
            DetailHeroAppBar(
              title: detail.title,
              imageUrl: cover,
              accent: accent,
              eyebrow: _eyebrowFor(detail.kind, detail.source),
              eyebrowIcon: _eyebrowIconFor(detail.kind, detail.source),
              placeholderIcon: _eyebrowIconFor(detail.kind, detail.source),
              subtitle: [
                if (detail.isCollab) HeroMeta('Společný · ${detail.members.join(', ')}'),
                if ((detail.description ?? _artistsLine(items)) case final line?) HeroMeta(line),
              ],
              meta: [
                if (detail.kind == 'CHART')
                  HeroMetaItem(Symbols.trophy_rounded, 'Top ${detail.itemCount}', emphasized: true),
                if (detail.isReadOnly && detail.generatedAt != null)
                  HeroMetaItem(Symbols.update_rounded, heroUpdatedLabel(detail.generatedAt!)),
                HeroMetaItem(Symbols.queue_music_rounded, heroTrackCount(items.length)),
              ],
              mosaicUrls: detail.coverUrls,
              // Vlastní mixy (roky, Denní mixy, mixy kategorií): stejný
              // generativní obal jako na kartě na Domů, ne fotka interpreta.
              // Bez nápisů -- druh a název už říká štítek a titulek vedle (dřív
              // třikrát "Tvůj mix", design audit #3).
              artwork: mixSpec == null ? null : MixArtwork(spec: mixSpec, labels: false),
              artworkBackdrop: mixSpec == null ? null : MixArtwork(spec: mixSpec, labels: false),
              // Audit UI: hlavní akce + ⋯ (rádio, sdílení a mazání v menu --
              // koš už není jako kolečko v hlavičce).
              actions: [
                if (readOnly)
                  HeroAction(
                    icon: pinned ? Symbols.library_add_check_rounded : Symbols.library_add_rounded,
                    tooltip: pinned ? 'V knihovně (aktualizuje se)' : 'Uložit do knihovny',
                    onPressed: () => pinned ? _unpin(context, detail) : _saveToLibrary(context, detail),
                  ),
                HeroAction(
                  icon: Symbols.more_horiz_rounded,
                  tooltip: 'Další možnosti',
                  onPressed: () => showCollectionActions(
                    context,
                    kind: CollectionKind.playlist,
                    id: detail.id,
                    title: detail.title,
                    subtitle: detail.description,
                    imageUrl: detail.coverUrls.firstOrNull,
                    isRadio: detail.source?.startsWith('radio:') ?? false,
                    onSaveCopy: readOnly && !pinned ? () => _saveToLibrary(context, detail) : null,
                    onDelete: readOnly || detail.isMember ? null : () => _confirmDelete(context),
                    onEdit: readOnly || detail.isMember ? null : () => _editPlaylist(context, detail),
                    onInvite: readOnly || detail.isMember ? null : () => _invite(context, detail),
                    onLeave: detail.isMember ? () => _leave(context, detail) : null,
                  ),
                ),
              ],
            ),
            ...detailContentSlivers(context, [
              if (items.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Symbols.queue_music_rounded,
                    message: 'Playlist je zatím prázdný – přidej skladby přes „Přidat do playlistu“ '
                        'v nabídce u skladby (dlouhý stisk nebo ⋯).',
                  ),
                )
              else ...[
                if (wrappedPeriodForSource(detail.source) case final period?)
                  SliverToBoxAdapter(child: WrappedLaunchCard(period: period)),
                SliverToBoxAdapter(
                  child: ListenableBuilder(
                    listenable: _collection,
                    builder: (context, _) => TrackCollectionToolbar(
                      controller: _collection,
                      allTracks: items,
                      visibleTracks: _collection.apply(items),
                      sourceLabel: detail.title,
                      onRemoveSelected: readOnly ? null : (selected) => _removeTracks(selected),
                      // Vlastní playlist: stáhnout celý na pozadí (žebříček ne --
                      // 100 skladeb najednou by zahltilo stahování).
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: _collection,
                  builder: (context, _) => _trackList(detail, items),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _trackList(PlaylistDetailModel detail, List<RecordingModel> items) {
    final visible = _collection.apply(items);
    if (visible.isEmpty) {
      return const SliverToBoxAdapter(child: EmptyState(compact: true, message: 'Filtru nic neodpovídá.'));
    }

    TrackTile tileFor(RecordingModel r, List<RecordingModel> queue) => TrackTile(
          recording: r,
          // Společný playlist: kdo skladbu přidal.
          subtitle: (detail.addedBy[r.id] ?? '').isNotEmpty
              ? '${r.artistName ?? ''} · přidal(a) ${detail.addedBy[r.id]}'
              : null,
          queueRecordings: queue,
          sourceLabel: detail.title,
          selectionMode: _collection.selecting,
          selected: _collection.isSelected(r.id),
          onSelectedChanged: (value) => _collection.toggle(r.id, value),
          extraMenuActions: [
            if (!detail.isReadOnly)
              TrackMenuAction(
                icon: Symbols.playlist_remove_rounded,
                label: 'Odebrat z playlistu',
                destructive: true,
                onSelected: () => _removeTracks([r]),
              ),
          ],
        );

    final canReorder = !detail.isReadOnly && !_collection.isModified && !_collection.selecting;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
      sliver: canReorder
          ? SliverReorderableList(
              itemCount: visible.length,
              onReorderItem: (oldIndex, newIndex) => _onReorder(oldIndex, newIndex, items),
              itemBuilder: (context, index) => ReorderableDelayedDragStartListener(
                key: ValueKey(visible[index].id),
                index: index,
                child: tileFor(visible[index], visible),
              ),
            )
          : SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) => tileFor(visible[index], visible),
            ),
    );
  }

  Future<void> _onReorder(int oldIndex, int newIndex, List<RecordingModel> items) async {
    // `onReorderItem` už `newIndex` sám koriguje na pozici PO odebrání.
    final reordered = List.of(items);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    setState(() {
      _items = reordered;
      _reordering = true;
    });
    try {
      await ref.read(playlistsRepositoryProvider).reorderItems(widget.playlistId, reordered.map((r) => r.id).toList());
    } catch (_) {
      ref.invalidate(playlistDetailProvider(widget.playlistId));
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  Future<void> _removeTracks(List<RecordingModel> tracks) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ids = tracks.map((r) => r.id).toSet();
    setState(() {
      _items = _items?.where((r) => !ids.contains(r.id)).toList();
      _reordering = true;
    });
    try {
      final repo = ref.read(playlistsRepositoryProvider);
      for (final id in ids) {
        await repo.removeItem(widget.playlistId, id);
      }
      showToast(messenger, ids.length == 1 ? 'Skladba odebrána' : 'Odebráno: ${songsCount(ids.length)}');
    } catch (e) {
      showToast(messenger, 'Odebrání selhalo: $e');
    } finally {
      ref.invalidate(myPlaylistsProvider);
      // Počkat na čerstvá data, než se zrcadlo znovu synchronizuje -- jinak
      // by odebrané skladby na okamžik naskočily zpátky.
      try {
        ref.invalidate(playlistDetailProvider(widget.playlistId));
        await ref.read(playlistDetailProvider(widget.playlistId).future);
      } catch (_) {}
      if (mounted) setState(() => _reordering = false);
    }
  }

  MixArtSpec? _mixSpec(PlaylistDetailModel detail) {
    final source = detail.source ?? '';
    String? group;
    Color? color;
    if (source.startsWith('personal:category-mix:')) {
      final id = source.split(':').last;
      final category = ref.watch(browseCategoriesProvider).valueOrNull?.where((c) => c.id == id).firstOrNull;
      group = category?.group;
      color = category?.color;
    }
    return mixArtForSource(
      source: detail.source,
      title: detail.title,
      photos: detail.coverUrls,
      color: color,
      categoryGroup: group,
    );
  }

  /// Štítek nad názvem -- u vlastních mixů podle zdroje (roční top skladby
  /// nejsou "Denní mix", i když jsou stejného druhu).
  String _eyebrowFor(String kind, String? source) {
    final s = source ?? '';
    if (s.startsWith('personal:year:')) return 'Top skladby roku';
    if (s.startsWith('personal:decade:')) return 'Dekáda';
    if (s.startsWith('personal:discover-weekly')) return 'Objevy týdne';
    if (s.startsWith('personal:category-mix:') ||
        s.startsWith('personal:on-repeat') ||
        s.startsWith('personal:throwback')) {
      return 'Tvůj mix';
    }
    return switch (kind) {
      'CHART' => 'Žebříček',
      'GENRE' => 'Žánr',
      'EDITORIAL' => 'Výběr',
      'PERSONAL_MIX' => 'Denní mix',
      'GENERATED_RECOMMENDATION' => 'Mix',
      _ => 'Playlist',
    };
  }

  IconData _eyebrowIconFor(String kind, String? source) {
    final s = source ?? '';
    if (s.startsWith('personal:year:') || s.startsWith('personal:decade:')) return Symbols.equalizer_rounded;
    return switch (kind) {
      'CHART' => Symbols.trending_up_rounded,
      'GENRE' => Symbols.category_rounded,
      'EDITORIAL' => Symbols.star_rounded,
      'PERSONAL_MIX' || 'GENERATED_RECOMMENDATION' => Symbols.library_music_rounded,
      _ => Symbols.queue_music_rounded,
    };
  }

  /// Bez popisu: "Interpret A, Interpret B a další" podle nejčastějších
  /// interpretů v playlistu (jako popisky mixů na Domů).
  String? _artistsLine(List<RecordingModel> items) {
    final counts = <String, int>{};
    for (final r in items) {
      final name = r.artistName;
      if (name != null && name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final top =
        (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => e.key).take(2).toList();
    return counts.length > top.length ? '${top.join(', ')} a další' : top.join(' a ');
  }

  /// Pozvat do společného playlistu: odkaz s kódem (seznam profilů se
  /// nikomu neukazuje). Kdo ho otevře, může přidávat a odebírat skladby.
  Future<void> _invite(BuildContext context, PlaylistDetailModel detail) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final res = await ref.read(apiClientProvider).postJson('/playlists/${detail.id}/invite');
      final url = '${AppConfig.sharedOrigin}/#${res['path']}'; // router je hashový (jako share_link)
      await Clipboard.setData(ClipboardData(text: url));
      showToast(messenger, 'Odkaz na společný playlist zkopírován – pošli ho, kdo ho otevře, může ho upravovat s tebou');
    } catch (e) {
      showToast(messenger, 'Pozvánku se nepodařilo vytvořit: $e');
    }
  }

  Future<void> _leave(BuildContext context, PlaylistDetailModel detail) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(apiClientProvider).deleteJson('/playlists/${detail.id}/members/me');
      ref.invalidate(myPlaylistsProvider);
      showToast(messenger, 'Opustil(a) jsi „${detail.title}“');
      if (context.mounted) context.pop();
    } catch (e) {
      showToast(messenger, 'Nepodařilo se: $e');
    }
  }

  /// ⋯ › Upravit: název, krátký popis a vlastní obal (místo mozaiky).
  Future<void> _editPlaylist(BuildContext context, PlaylistDetailModel detail) async {
    final title = TextEditingController(text: detail.title);
    final description = TextEditingController(text: detail.description ?? '');
    final messenger = ScaffoldMessenger.maybeOf(context);
    final api = ref.read(apiClientProvider);
    final saved = await showGlassSheet<bool>(
      context,
      builder: (sheet) => GlassSheet(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md + MediaQuery.viewInsetsOf(sheet).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Upravit playlist', style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Název')),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                controller: description,
                maxLines: 3,
                minLines: 1,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Krátký popis (nepovinné)'),
              ),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Vybrat obal…',
                      icon: Symbols.image_rounded,
                      style: GlassButtonStyle.tonal,
                      onPressed: () async {
                        final picked = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
                        final file = picked?.files.firstOrNull;
                        if (file?.bytes == null) return;
                        try {
                          await api.postMultipart('/playlists/${detail.id}/cover',
                              fieldName: 'file', bytes: file!.bytes!, filename: file.name);
                          showToast(messenger, 'Obal nastaven');
                        } catch (e) {
                          showToast(messenger, 'Obal se nepodařilo nahrát: $e');
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  GlassButton(
                    label: 'Mozaika',
                    icon: Symbols.grid_view_rounded,
                    style: GlassButtonStyle.plain,
                    onPressed: () async {
                      try {
                        await api.deleteJson('/playlists/${detail.id}/cover');
                        showToast(messenger, 'Zpátky na mozaiku z obalů skladeb');
                      } catch (_) {}
                    },
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              GlassButton(
                label: 'Uložit',
                style: GlassButtonStyle.prominent,
                expand: true,
                onPressed: () => Navigator.of(sheet).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      try {
        await api.patchJson('/playlists/${detail.id}', body: {
          'title': title.text.trim(),
          'description': description.text.trim(),
        });
      } catch (e) {
        showToast(messenger, 'Uložení selhalo: $e');
      }
    }
    title.dispose();
    description.dispose();
    ref.invalidate(myPlaylistsProvider);
    ref.invalidate(playlistDetailProvider(detail.id));
  }

  /// Uložit mix / žebříček: zachytit dnešní stav (kopie), nebo připnout živý.
  Future<void> _saveToLibrary(BuildContext context, PlaylistDetailModel detail) async {
    final choice = await showGlassSheet<String>(
      context,
      builder: (sheet) {
        Widget option(String value, IconData icon, String title, String subtitle) => ListTile(
              shape: AppShapes.md,
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              onTap: () => Navigator.of(sheet).pop(value),
            );
        return GlassSheet(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                  child: Text('Uložit „${detail.title}“', style: Theme.of(sheet).textTheme.titleMedium),
                ),
                option('live', Symbols.autorenew_rounded, 'Nechat aktualizovat',
                    'V knihovně, ale dál se mění jako tady'),
                option('copy', Symbols.photo_camera_rounded, 'Zachytit tenhle stav',
                    'Vlastní playlist se dnešními skladbami, už se nezmění'),
              ],
            ),
          ),
        );
      },
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'copy') return _copyToLibrary(context, detail);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(playlistsRepositoryProvider).pin(detail.id);
      ref.invalidate(myPlaylistsProvider);
      showToast(messenger, '„${detail.title}“ je v knihovně a dál se aktualizuje');
    } catch (e) {
      showToast(messenger, 'Uložení selhalo: $e');
    }
  }

  Future<void> _unpin(BuildContext context, PlaylistDetailModel detail) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(playlistsRepositoryProvider).unpin(detail.id);
      ref.invalidate(myPlaylistsProvider);
      showToast(messenger, '„${detail.title}“ odebrán z knihovny');
    } catch (e) {
      showToast(messenger, 'Nepodařilo se: $e');
    }
  }

  Future<void> _copyToLibrary(BuildContext context, PlaylistDetailModel detail) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final copy = await ref.read(playlistsRepositoryProvider).copy(detail.id);
      ref.invalidate(myPlaylistsProvider);
      messenger?.showSnackBar(
        SnackBar(persist: false, 
          content: Text('„${detail.title}“ přidán do knihovny'),
          action: SnackBarAction(label: 'Otevřít', onPressed: () => context.push('/playlists/${copy.id}')),
        ),
      );
    } catch (e) {
      showToast(messenger, 'Přidání selhalo: $e');
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final title = ref.read(playlistDetailProvider(widget.playlistId)).valueOrNull?.title ?? 'playlist';
    final deleted = await confirmDeletePlaylist(context, ref, id: widget.playlistId, title: title);
    if (deleted && context.mounted) Navigator.of(context).pop();
  }
}
