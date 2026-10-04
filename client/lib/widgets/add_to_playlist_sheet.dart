import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/providers.dart';
import 'glass/glass.dart';
import 'state_views.dart';
import 'glass/expressive_shapes.dart';
import '../core/cz_plural.dart';
import 'toast.dart';

/// Bottom sheet "Přidat do playlistu" -- seznam vlastních playlistů + řádek
/// na založení nového rovnou z místa. Jedna skladba (`recordingId`, přehrávač/
/// kontextové menu) nebo víc najednou (`recordingIds`, hromadný výběr v
/// seznamu skladeb).
Future<void> showAddToPlaylistSheet(BuildContext context, {String? recordingId, List<String>? recordingIds}) {
  final ids = recordingIds ?? [if (recordingId != null) recordingId];
  return showGlassSheet(
    context,
    builder: (context) => _AddToPlaylistSheet(recordingIds: ids),
  );
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  const _AddToPlaylistSheet({required this.recordingIds});
  final List<String> recordingIds;

  @override
  ConsumerState<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  final _newPlaylistController = TextEditingController();
  bool _creating = false;

  /// Právě se přidává (do kteréhokoli playlistu) -- dvojí klepnutí jinak
  /// přidalo skladby dvakrát.
  bool _busy = false;

  @override
  void dispose() {
    _newPlaylistController.dispose();
    super.dispose();
  }

  Future<void> _createAndAdd() async {
    final title = _newPlaylistController.text.trim();
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (title.isEmpty) {
      showToast(messenger, 'Playlist potřebuje název.');
      return;
    }
    setState(() {
      _busy = true;
      _creating = true;
    });
    final repo = ref.read(playlistsRepositoryProvider);
    try {
      final playlist = await repo.create(title);
      await _addAll(playlist.id, title, messenger, created: true);
    } catch (_) {
      showToast(messenger, 'Playlist se nepodařilo vytvořit.');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _creating = false;
        });
      }
    }
  }

  Future<void> _addTo(String playlistId, String playlistTitle) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      await _addAll(playlistId, playlistTitle, messenger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Přidá skladby po jedné; chyba = toast s tím, kolik prošlo (dřív výjimka
  /// tiše spadla a nově založený playlist zůstal prázdný bez vysvětlení).
  Future<void> _addAll(String playlistId, String playlistTitle, ScaffoldMessengerState? messenger,
      {bool created = false}) async {
    final repo = ref.read(playlistsRepositoryProvider);
    var added = 0;
    try {
      for (final id in widget.recordingIds) {
        await repo.addItem(playlistId, id);
        added++;
      }
    } catch (_) {
      ref.invalidate(myPlaylistsProvider);
      final prefix = created ? 'Playlist „$playlistTitle“ vytvořen, ale ' : '';
      showToast(
        messenger,
        added == 0
            ? '${prefix}skladby se do „$playlistTitle“ nepodařilo přidat.'
            : '${prefix}přidáno jen ${songsCount(added)} z ${widget.recordingIds.length}.',
      );
      return;
    }
    ref.invalidate(myPlaylistsProvider);
    if (mounted) Navigator.of(context).pop();
    _confirm(messenger, playlistTitle);
  }

  void _confirm(ScaffoldMessengerState? messenger, String playlistTitle) {
    final count = widget.recordingIds.length;
    final what = count == 1 ? 'Skladba přidána' : 'Přidáno: ${songsCount(count)}';
    showToast(messenger, '$what do „$playlistTitle“');
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(myPlaylistsProvider);
    // SafeArea je uvnitř GlassSheet (jako u ostatních sheetů) -- vnější
    // odsazovala sklo od spodního okraje.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.recordingIds.length > 1
                    ? 'Přidat ${songsCount(widget.recordingIds.length)} do playlistu'
                    : 'Přidat do playlistu',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newPlaylistController,
                      decoration: const InputDecoration(hintText: 'Nový playlist…', isDense: true),
                      enabled: !_busy,
                      onSubmitted: (_) => _createAndAdd(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Vytvořit playlist',
                    icon:
                        _creating ? const ExpressiveLoadingIndicator(size: 22) : const Icon(Symbols.add_circle_rounded),
                    onPressed: _busy ? null : _createAndAdd,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              playlists.when(
                // Připnuté mixy se mění samy -- do nich přidávat nejde.
                data: (all) => [
                  for (final p in all)
                    if (!p.pinned) p
                ].isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('Zatím žádné playlisty – založ první výš.'),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: all.where((p) => !p.pinned).length,
                          itemBuilder: (context, index) {
                            final playlist = all.where((p) => !p.pinned).elementAt(index);
                            return ListTile(
                              leading: Icon(playlist.collab ? Symbols.group_rounded : Symbols.queue_music_rounded),
                              title: Text(playlist.title),
                              subtitle:
                                  Text('${playlist.collab ? 'Společný · ' : ''}${songsCount(playlist.itemCount)}'),
                              enabled: !_busy,
                              onTap: () => _addTo(playlist.id, playlist.title),
                            );
                          },
                        ),
                      ),
                loading: () => const InlineSpinner(),
                error: (error, stack) => ErrorState(
                  compact: true,
                  message: 'Nepodařilo se načíst playlisty.',
                  onRetry: () => ref.invalidate(myPlaylistsProvider),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
