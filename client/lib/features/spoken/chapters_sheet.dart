import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../../widgets/state_views.dart';
import 'spoken_data.dart';
import 'spoken_screens.dart' show playBook;

/// Kapitoly hrající knihy: vložené kapitoly (m4b) aktuálního souboru, jinak
/// soubory knihy. Aktuální je zvýrazněná, klepnutí na ni přeskočí.
Future<void> showChaptersSheet(BuildContext context, String bookId) =>
    showGlassSheet<void>(context, builder: (_) => GlassSheet(child: _ChaptersList(bookId: bookId)));

String _clock(int ms) {
  final s = ms ~/ 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two((s % 3600) ~/ 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

class _ChaptersList extends ConsumerWidget {
  const _ChaptersList({required this.bookId});
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spokenBookProvider(bookId));
    final current = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId));
    final positionMs = ref.watch(audioPlayerControllerProvider.select((s) => s.position.inMilliseconds));
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      child: async.when(
        loading: () => const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: LinearProgressIndicator()),
        error: (e, _) => const EmptyState(icon: Symbols.toc_rounded, message: 'Kapitoly se nepodařilo načíst.'),
        data: (book) {
          final fileIndex = book.files.indexWhere((f) => spokenQueueId(book.id, f.id) == current);
          final file = fileIndex >= 0 ? book.files[fileIndex] : null;
          // Kapitoly v souboru (m4b) -- jinak jsou kapitolami soubory.
          final inFile = file != null && file.chapters.length > 1;
          final rows = inFile
              ? [for (final c in file.chapters) (title: c.title, startMs: c.startMs, fileIndex: fileIndex)]
              : [for (final (i, f) in book.files.indexed) (title: f.title ?? 'Část ${i + 1}', startMs: 0, fileIndex: i)];
          var currentRow = -1;
          for (var i = 0; i < rows.length; i++) {
            final r = rows[i];
            if (inFile ? r.startMs <= positionMs : r.fileIndex == fileIndex) currentRow = i;
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                child: Text('Kapitoly', style: theme.textTheme.titleMedium),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final playing = i == currentRow;
                    return ListTile(
                      dense: true,
                      selected: playing,
                      leading: playing ? const Icon(Symbols.graphic_eq_rounded) : Text('${i + 1}', style: muted),
                      title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: inFile ? Text(_clock(r.startMs), style: muted) : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (r.fileIndex == fileIndex) {
                          controller.seek(Duration(milliseconds: r.startMs));
                        } else {
                          // Soubor je ve frontě -> skočit na něj; fronta (i hudba
                          // za knihou) zůstane. Jinak kniha znovu od té kapitoly.
                          final at = Duration(milliseconds: r.startMs);
                          final id = spokenQueueId(book.id, book.files[r.fileIndex].id);
                          final index = ref.read(audioPlayerControllerProvider).queue.indexWhere((q) => q.recordingId == id);
                          if (index >= 0) {
                            controller.skipToIndex(index, position: at);
                          } else {
                            playBook(ref, book, fileIndex: r.fileIndex, position: at);
                          }
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          );
        },
      ),
    );
  }
}
