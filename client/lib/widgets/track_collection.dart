import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../theme/design_tokens.dart';
import 'add_to_playlist_sheet.dart';
import 'glass/glass.dart';
import 'queue_action_bar.dart';
import 'track_actions.dart';
import '../core/cz_plural.dart';

enum TrackSort { original, title, artist, duration }

const _sortLabels = {
  TrackSort.original: 'Pořadí',
  TrackSort.title: 'Název',
  TrackSort.artist: 'Interpret',
  TrackSort.duration: 'Délka',
};

/// Filtrování/řazení/hromadný výběr v jednom seznamu skladeb (album,
/// playlist, oblíbené, knihovna) -- UX vzor ze Spotube's
/// `track_presentation/presentation_modifiers.dart` (BSD-4), vlastní
/// implementace nad naším `RecordingModel`. Stav drží obrazovka (jeden
/// controller na seznam), `TrackCollectionToolbar` ho jen zobrazuje/mění.
class TrackCollectionController extends ChangeNotifier {
  String _query = '';
  TrackSort _sort = TrackSort.original;
  bool _selecting = false;
  final Set<String> _selected = {};

  String get query => _query;
  TrackSort get sort => _sort;
  bool get selecting => _selecting;
  Set<String> get selected => Set.unmodifiable(_selected);

  /// `true`, když zobrazený seznam není původní pořadí -- např. ruční
  /// přeskládání playlistu dává smysl jen nad nefiltrovaným originálem.
  bool get isModified => _query.isNotEmpty || _sort != TrackSort.original;

  set query(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  set sort(TrackSort value) {
    if (value == _sort) return;
    _sort = value;
    notifyListeners();
  }

  void setSelecting(bool value) {
    _selecting = value;
    if (!value) _selected.clear();
    notifyListeners();
  }

  bool isSelected(String id) => _selected.contains(id);

  void toggle(String id, bool value) {
    value ? _selected.add(id) : _selected.remove(id);
    notifyListeners();
  }

  void selectAll(Iterable<RecordingModel> items) {
    final ids = items.map((r) => r.id).toSet();
    if (_selected.containsAll(ids)) {
      _selected.removeAll(ids);
    } else {
      _selected.addAll(ids);
    }
    notifyListeners();
  }

  List<RecordingModel> apply(List<RecordingModel> items) {
    final q = _fold(_query.trim());
    var result = q.isEmpty
        ? List.of(items)
        : items.where((r) => _fold(r.title).contains(q) || _fold(r.artistName ?? '').contains(q)).toList();
    switch (_sort) {
      case TrackSort.original:
        break;
      case TrackSort.title:
        result.sort((a, b) => _fold(a.title).compareTo(_fold(b.title)));
      case TrackSort.artist:
        result.sort((a, b) => _fold(a.artistName ?? '').compareTo(_fold(b.artistName ?? '')));
      case TrackSort.duration:
        result.sort((a, b) => (a.durationMs ?? 0).compareTo(b.durationMs ?? 0));
    }
    return result;
  }
}

const _diacritics = {
  'á': 'a',
  'č': 'c',
  'ď': 'd',
  'é': 'e',
  'ě': 'e',
  'í': 'i',
  'ň': 'n',
  'ó': 'o',
  'ř': 'r',
  'š': 's',
  'ť': 't',
  'ú': 'u',
  'ů': 'u',
  'ý': 'y',
  'ž': 'z',
  'ä': 'a',
  'ö': 'o',
  'ü': 'u',
  'ß': 'ss',
};

/// Lowercase bez diakritiky -- "prilis" najde "Příliš".
String _fold(String input) {
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final ch in lower.split('')) {
    buffer.write(_diacritics[ch] ?? ch);
  }
  return buffer.toString();
}

/// Veřejná verze pro ostatní obrazovky (autocomplete historie hledání).
String foldForSearch(String input) => _fold(input);

/// Lišta nad seznamem skladeb: Přehrát/Zamíchat (nad aktuálně zobrazeným
/// pořadím), filtr podle názvu/interpreta, řazení a přepnutí do výběru.
/// Ve výběrovém režimu nahradí sama sebe lištou hromadných akcí.
class TrackCollectionToolbar extends ConsumerStatefulWidget {
  const TrackCollectionToolbar({
    super.key,
    required this.controller,
    required this.allTracks,
    required this.visibleTracks,
    this.sourceLabel,
    this.albumArtUrl,
    this.artistName,
    this.onRemoveSelected,
    this.removeLabel = 'Odebrat',
    this.trailing,
    this.showFilter = true,
  });

  final TrackCollectionController controller;
  final List<RecordingModel> allTracks;
  final List<RecordingModel> visibleTracks;
  final String? sourceLabel;
  final String? albumArtUrl;
  final String? artistName;

  /// Jen ve vlastním playlistu -- přidá do hromadných akcí "Odebrat".
  final Future<void> Function(List<RecordingModel> selected)? onRemoveSelected;

  /// Popisek hromadného odebrání ("Odebrat" z playlistu / "Odebrat z knihovny").
  final String removeLabel;

  /// Extra ovladač vpravo (např. seznam/karty přepínač v Knihovně).
  final Widget? trailing;


  /// `false` v Knihovně -- tam filtr zastane horní "Hledat v knihovně"
  /// (dvě pole pod sebou působila jako dvě různé věci).
  final bool showFilter;

  @override
  ConsumerState<TrackCollectionToolbar> createState() => _TrackCollectionToolbarState();
}

const _filterMinTracks = 20;

class _TrackCollectionToolbarState extends ConsumerState<TrackCollectionToolbar> {
  late final TextEditingController _filter = TextEditingController(text: widget.controller.query);

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<RecordingModel> get _selectedTracks =>
      widget.allTracks.where((r) => widget.controller.isSelected(r.id)).toList();

  void _addSelectedToQueue() {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    final player = ref.read(audioPlayerControllerProvider.notifier);
    for (final r in tracks) {
      player.addToQueue(nowPlayingInfoFor(r, artworkUrl: widget.albumArtUrl, artistNameFallback: widget.artistName));
    }
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('Do fronty: ${songsCount(tracks.length)}')));
    widget.controller.setSelecting(false);
  }

  void _addSelectedToPlaylist() {
    final ids = _selectedTracks.map((r) => r.id).toList();
    if (ids.isEmpty) return;
    showAddToPlaylistSheet(context, recordingIds: ids);
    widget.controller.setSelecting(false);
  }

  Future<void> _removeSelected() async {
    final tracks = _selectedTracks;
    if (tracks.isEmpty || widget.onRemoveSelected == null) return;
    await widget.onRemoveSelected!(tracks);
    widget.controller.setSelecting(false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);

    if (c.selecting) {
      final count = c.selected.length;
      final allSelected = widget.visibleTracks.isNotEmpty && widget.visibleTracks.every((r) => c.isSelected(r.id));
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xxs),
        // Lišta výběru je plovoucí (akce nad seznamem) -- sklo + stín.
        child: GlassContainer(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          shadow: true,
          liquid: true,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xxs),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              GlassIconButton(
                icon: Symbols.close_rounded,
                tooltip: 'Zrušit výběr',
                style: GlassButtonStyle.plain,
                onPressed: () => c.setSelecting(false),
              ),
              Text('$count vybráno', style: theme.textTheme.titleSmall),
              GlassButton(
                label: allSelected ? 'Zrušit vše' : 'Vybrat vše',
                icon: allSelected ? Symbols.deselect_rounded : Symbols.select_all_rounded,
                style: GlassButtonStyle.plain,
                compact: true,
                onPressed: () => c.selectAll(widget.visibleTracks),
              ),
              GlassButton(
                label: 'Do fronty',
                icon: Symbols.queue_music_rounded,
                compact: true,
                onPressed: count == 0 ? null : _addSelectedToQueue,
              ),
              GlassButton(
                label: 'Do playlistu',
                icon: Symbols.playlist_add_rounded,
                compact: true,
                onPressed: count == 0 ? null : _addSelectedToPlaylist,
              ),
              if (widget.onRemoveSelected != null)
                GlassButton(
                  label: widget.removeLabel,
                  icon: Symbols.delete_rounded,
                  compact: true,
                  destructive: true,
                  onPressed: count == 0 ? null : _removeSelected,
                ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: QueueActionBar(
                    tracks: widget.visibleTracks,
                    sourceLabel: widget.sourceLabel,
                    albumArtUrl: widget.albumArtUrl,
                    artistName: widget.artistName,
                  ),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              // Inline filtr v obsahu -- plochá kapsle, ne sklo (HIG Materials).
              // Jen u delších seznamů (Oblíbené, velké playlisty) -- u alba o
              // pár skladbách působil jako nefunkční prvek navíc (živě nahlášeno).
              if (!widget.showFilter || (widget.allTracks.length < _filterMinTracks && c.query.isEmpty))
                const Spacer()
              else
                Expanded(
                  child: GlassSearchField(
                    controller: _filter,
                    hintText: 'Filtrovat skladby…',
                    glass: false,
                    compact: true,
                    showCancel: false,
                    leadingIcon: Symbols.filter_list_rounded,
                    onChanged: (value) => c.query = value,
                    onCleared: () => setState(() => c.query = ''),
                  ),
                ),
              const SizedBox(width: AppSpacing.xs),
              PopupMenuButton<TrackSort>(
                tooltip: 'Řazení',
                initialValue: c.sort,
                onSelected: (value) => c.sort = value,
                itemBuilder: (context) => [
                  for (final entry in _sortLabels.entries)
                    CheckedPopupMenuItem(value: entry.key, checked: entry.key == c.sort, child: Text(entry.value)),
                ],
                child: Chip(
                  avatar: const Icon(Symbols.sort_rounded, size: 18),
                  label: Text(_sortLabels[c.sort]!),
                ),
              ),
              IconButton(
                icon: const Icon(Symbols.checklist_rounded),
                tooltip: 'Vybrat více',
                onPressed: widget.allTracks.isEmpty ? null : () => c.setSelecting(true),
              ),
            ],
          ),
          if (c.query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: Text(
                '${widget.visibleTracks.length} z ${widget.allTracks.length} skladeb',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
