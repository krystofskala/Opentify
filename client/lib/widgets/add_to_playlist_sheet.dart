import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/providers.dart';
import 'glass_container.dart';
import 'state_views.dart';

/// Bottom sheet "Přidat do playlistu" -- seznam vlastních playlistů + řádek
/// na založení nového rovnou z místa. Jedna skladba (`recordingId`, přehrávač/
/// kontextové menu) nebo víc najednou (`recordingIds`, hromadný výběr v
/// seznamu skladeb).
Future<void> showAddToPlaylistSheet(BuildContext context, {String? recordingId, List<String>? recordingIds}) {
  final ids = recordingIds ?? [if (recordingId != null) recordingId];
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
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

  @override
  void dispose() {
    _newPlaylistController.dispose();
    super.dispose();
  }

  Future<void> _createAndAdd() async {
    final title = _newPlaylistController.text.trim();
    if (title.isEmpty || _creating) return;
    setState(() => _creating = true);
    try {
      final repo = ref.read(playlistsRepositoryProvider);
      final playlist = await repo.create(title);
      for (final id in widget.recordingIds) {
        await repo.addItem(playlist.id, id);
      }
      ref.invalidate(myPlaylistsProvider);
      if (mounted) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop();
        _confirm(messenger, title);
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _addTo(String playlistId, String playlistTitle) async {
    final repo = ref.read(playlistsRepositoryProvider);
    for (final id in widget.recordingIds) {
      await repo.addItem(playlistId, id);
    }
    ref.invalidate(myPlaylistsProvider);
    if (mounted) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      _confirm(messenger, playlistTitle);
    }
  }

  void _confirm(ScaffoldMessengerState? messenger, String playlistTitle) {
    final count = widget.recordingIds.length;
    final what = count == 1 ? 'Skladba přidána' : '$count skladeb přidáno';
    messenger?.showSnackBar(SnackBar(content: Text('$what do „$playlistTitle“')));
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(myPlaylistsProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: GlassContainer(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.recordingIds.length > 1
                      ? 'Přidat ${widget.recordingIds.length} skladeb do playlistu'
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
                        onSubmitted: (_) => _createAndAdd(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: _creating
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Symbols.add_circle_rounded),
                      onPressed: _creating ? null : _createAndAdd,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                playlists.when(
                  data: (items) => items.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('Zatím žádné playlisty -- založ první výš.'),
                        )
                      : ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final playlist = items[index];
                              return ListTile(
                                leading: const Icon(Symbols.queue_music_rounded),
                                title: Text(playlist.title),
                                subtitle: Text('${playlist.itemCount} skladeb'),
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
      ),
    );
  }
}
