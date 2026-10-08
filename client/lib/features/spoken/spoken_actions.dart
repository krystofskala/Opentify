import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/share_sheet.dart';
import '../../widgets/toast.dart';
import 'spoken_data.dart';
import 'spoken_screens.dart' show playBook;

/// Menu knihy (dlouhý stisk na knize, ⋯ na stránce knihy) -- stejný styl a
/// pořadí skupin jako hudební menu (`collection_actions.dart`): přehrát ·
/// fronta · přejít · stav poslechu · uložit · sdílet. Převzato z hudby
/// 8. 10. (uživatel: "podržení pro možnosti jako u skladby").
Future<void> showSpokenBookActions(BuildContext context, SpokenBook book) {
  HapticFeedback.selectionClick();
  return showGlassSheet<void>(context, builder: (_) => _BookActionsSheet(hostContext: context, book: book));
}

class _BookActionsSheet extends ConsumerWidget {
  const _BookActionsSheet({required this.hostContext, required this.book});
  final BuildContext hostContext;
  final SpokenBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.maybeOf(hostContext);
    final favs = ref.watch(spokenFavoritesProvider).valueOrNull;
    final saved = favs?.books.contains(book.id) ?? false;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    void close() => Navigator.of(context).pop();
    void toast(String t) => showToast(messenger, t);

    Future<SpokenBook?> full() async {
      try {
        return book.files.isNotEmpty ? book : await ref.read(spokenBookProvider(book.id).future);
      } catch (_) {
        toast('Knihu se nepodařilo načíst');
        return null;
      }
    }

    /// Díly od uloženého místa (rozposlouchaná kniha), jinak celá; první díl
    /// naváže na uloženou pozici, až začne hrát.
    List<NowPlayingInfo> fromSaved(SpokenBook b) {
      final queue = spokenQueue(b);
      final p = b.progress;
      if (p == null || p.finished) return queue;
      final i = b.files.indexWhere((f) => f.id == p.fileId);
      if (i < 0) return queue;
      ref.read(audioPlayerControllerProvider.notifier)
          .rememberStartPosition(queue[i].recordingId, Duration(milliseconds: p.positionMs));
      return queue.sublist(i);
    }

    Future<void> progress({required bool finished}) async {
      final b = await full();
      if (b == null || b.files.isEmpty) return;
      try {
        await ref.read(apiClientProvider).putJson('/spoken/books/${b.id}/progress', body: {
          'fileId': finished ? b.files.last.id : b.files.first.id,
          'positionMs': 0,
          'finished': finished,
        });
        ref.invalidate(spokenBookProvider(b.id));
        ref.invalidate(spokenBooksProvider);
        toast(finished ? 'Označeno jako dočtené' : 'Kniha začne znovu od začátku');
      } catch (_) {
        toast('Nepodařilo se uložit');
      }
    }

    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final playing = ref.read(audioPlayerControllerProvider).nowPlaying != null;

    return GlassSheet(
      // Průhledný Material: odezva klepnutí řádků je vidět i na skle.
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.sm),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Row(
                  children: [
                    ClipPath(
                      clipper: ShapeBorderClipper(shape: AppShapes.sm),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: ArtworkImage(url: book.coverUrl, icon: Symbols.menu_book_rounded),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(book.title, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                          if (book.byline.isNotEmpty)
                            Text(book.byline, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              if (book.canPlay)
                _Row(
                  icon: Symbols.play_arrow_rounded,
                  label: book.inProgress ? 'Pokračovat' : 'Přehrát',
                  onTap: () async {
                    // Síť dřív, zavřít až potom -- `ref` zavřeného sheetu už
                    // nejde použít (audit 8. 10.: nic se nestalo).
                    final b = await full();
                    if (b != null) playBook(ref, b);
                    if (context.mounted) close();
                  },
                ),
              if (book.canPlay && playing) ...[
                _Row(
                  icon: Symbols.playlist_play_rounded,
                  label: 'Přehrát jako další',
                  onTap: () async {
                    final b = await full();
                    if (b != null) {
                      await controller.playNextAll(fromSaved(b), sourceLabel: b.title);
                      toast('Kniha hraje jako další');
                    }
                    if (context.mounted) close();
                  },
                ),
                _Row(
                  icon: Symbols.queue_music_rounded,
                  label: 'Přidat do fronty',
                  onTap: () async {
                    final b = await full();
                    if (b != null) {
                      await controller.addAllToQueue(fromSaved(b), sourceLabel: b.title);
                      toast('Přidáno do fronty');
                    }
                    if (context.mounted) close();
                  },
                ),
              ],
              const _MenuDivider(),
              if (book.author != null)
                _Row(
                  icon: Symbols.person_rounded,
                  label: 'Přejít na autora',
                  onTap: () {
                    close();
                    hostContext.push(spokenPersonPath(book.author!));
                  },
                ),
              if (book.narrator != null)
                _Row(
                  icon: Symbols.record_voice_over_rounded,
                  label: 'Přejít na interpreta',
                  onTap: () {
                    close();
                    hostContext.push(spokenPersonPath(book.narrator!, narrator: true));
                  },
                ),
              if (book.author != null && book.seriesName != null && book.seriesName!.isNotEmpty)
                _Row(
                  icon: Symbols.format_list_numbered_rounded,
                  label: 'Řada: ${book.seriesName}',
                  onTap: () {
                    close();
                    hostContext.push(spokenSeriesPath(book.title, book.author!));
                  },
                ),
              const _MenuDivider(),
              if (book.isReady && !(book.progress?.finished ?? false))
                _Row(
                  icon: Symbols.check_circle_rounded,
                  label: 'Označit jako dočtené',
                  onTap: () async {
                    await progress(finished: true);
                    if (context.mounted) close();
                  },
                ),
              if (book.progress != null)
                _Row(
                  icon: Symbols.restart_alt_rounded,
                  label: 'Začít znovu od začátku',
                  onTap: () async {
                    await progress(finished: false);
                    if (context.mounted) close();
                  },
                ),
              if (favs != null)
                _Row(
                  icon: Symbols.favorite_rounded,
                  label: saved ? 'Odebrat z mých knih' : 'Uložit do mých knih',
                  onTap: () async {
                    try {
                      await setSpokenFavorite(ref, bookId: book.id, on: !saved);
                      toast(saved ? 'Odebráno z mých knih' : 'Uloženo do mých knih');
                    } catch (_) {
                      toast('Nepodařilo se uložit');
                    }
                    if (context.mounted) close();
                  },
                ),
              if (book.isReady)
                _Row(
                  icon: book.isDrama ? Symbols.menu_book_rounded : Symbols.theater_comedy_rounded,
                  label: book.isDrama ? 'Je to audiokniha' : 'Je to rozhlasová hra',
                  onTap: () async {
                    try {
                      await setSpokenKind(ref, book.id, book.isDrama ? 'book' : 'drama');
                      toast(book.isDrama ? 'Přesunuto mezi audioknihy' : 'Přesunuto mezi rozhlasové hry');
                    } catch (_) {
                      toast('Nepodařilo se uložit');
                    }
                    if (context.mounted) close();
                  },
                ),
              if (book.isReady) ...[
                _Row(
                  icon: Symbols.add_photo_alternate_rounded,
                  label: 'Nahrát vlastní obal',
                  onTap: () async {
                    final picked = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
                    final file = picked?.files.firstOrNull;
                    if (file?.bytes != null) {
                      try {
                        await uploadBookCover(ref, book.id, file!.bytes!, file.name);
                        toast('Obal nastaven');
                      } catch (_) {
                        toast('Obal se nepodařilo nahrát');
                      }
                    }
                    if (context.mounted) close();
                  },
                ),
                if (book.coverUrl != null)
                  _Row(
                    icon: Symbols.hide_image_rounded,
                    label: 'Nahlásit špatný obal',
                    onTap: () async {
                      try {
                        final other = await reportWrongBookCover(ref, book.id);
                        toast(other ? 'Obal vyměněn za jiný' : 'Obal odebrán – jiný se nenašel');
                      } catch (_) {
                        toast('Nepodařilo se, zkus to znovu');
                      }
                      if (context.mounted) close();
                    },
                  ),
              ],
              const _MenuDivider(),
              // Jen v Opentify (odkaz na knihu v appce) -- zdroj (SkTorrent,
              // Soulseek) se ven neposílá.
              _Row(
                icon: Symbols.ios_share_rounded,
                label: 'Sdílet…',
                onTap: () {
                  close();
                  showShareSheet(hostContext, title: book.title, artistName: book.author, opentifyPath: '/spoken/book/${book.id}');
                },
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        shape: AppShapes.md,
        leading: Icon(icon),
        title: Text(label),
        onTap: onTap,
      );
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xxs, horizontal: AppSpacing.md),
        child: Divider(height: 1),
      );
}
