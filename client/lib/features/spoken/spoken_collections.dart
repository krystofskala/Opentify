import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/media_card.dart' show ArtworkImage, MediaCard;
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import 'spoken_data.dart';
import 'spoken_screens.dart' show playBook;

/// Sbírky knih profilu -- jako playlisty u hudby (souhrn 8. 10. #17).
typedef SpokenCollection = ({String id, String title, List<String> bookIds, String? coverUrl});

SpokenCollection _fromJson(Map<String, dynamic> j) => (
      id: j['id'] as String,
      title: j['title'] as String? ?? '',
      bookIds: [for (final b in j['bookIds'] as List<dynamic>? ?? const []) b as String],
      coverUrl: spokenCoverUrl(j['coverUrl'] as String?),
    );

final spokenCollectionsProvider = FutureProvider.autoDispose<List<SpokenCollection>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/collections');
  return [for (final c in (json['collections'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()) _fromJson(c)];
});

Future<SpokenCollection> createCollection(WidgetRef ref, String title) async {
  final json = await ref.read(apiClientProvider).postJson('/spoken/collections', body: {'title': title});
  ref.invalidate(spokenCollectionsProvider);
  return _fromJson(json);
}

Future<void> addToCollection(WidgetRef ref, String collectionId, String bookId) async {
  await ref.read(apiClientProvider).postJson('/spoken/collections/$collectionId/books', body: {'bookId': bookId});
  ref.invalidate(spokenCollectionsProvider);
}

Future<void> removeFromCollection(WidgetRef ref, String collectionId, String bookId) async {
  await ref.read(apiClientProvider).deleteJson('/spoken/collections/$collectionId/books/$bookId');
  ref.invalidate(spokenCollectionsProvider);
}

Future<String?> _askTitle(BuildContext context, {String initial = '', String title = 'Nová sbírka'}) async {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Název', hintText: 'Třeba Na dovolenou'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        GlassButton(label: 'Zrušit', style: GlassButtonStyle.plain, compact: true, onPressed: () => Navigator.of(context).pop()),
        GlassButton(
          label: 'Uložit',
          style: GlassButtonStyle.prominent,
          compact: true,
          onPressed: () => Navigator.of(context).pop(field.text.trim()),
        ),
      ],
    ),
  );
}

/// "Přidat do sbírky…" (z menu knihy): seznam sbírek + Nová sbírka.
Future<void> showAddToCollectionSheet(BuildContext context, WidgetRef ref, SpokenBook book) async {
  await showGlassSheet<void>(context, builder: (_) => GlassSheet(child: _AddSheet(book: book, hostContext: context)));
}

class _AddSheet extends ConsumerWidget {
  const _AddSheet({required this.book, required this.hostContext});
  final SpokenBook book;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.maybeOf(hostContext);
    final async = ref.watch(spokenCollectionsProvider);
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Text('Přidat do sbírky', style: theme.textTheme.titleMedium),
            ),
            ListTile(
              dense: true,
              shape: AppShapes.md,
              leading: const Icon(Symbols.add_rounded),
              title: const Text('Nová sbírka…'),
              onTap: () async {
                final title = await _askTitle(context);
                if (title == null || title.isEmpty) return;
                try {
                  final c = await createCollection(ref, title);
                  await addToCollection(ref, c.id, book.id);
                  showToast(messenger, 'Přidáno do sbírky „$title“');
                } catch (_) {
                  showToast(messenger, 'Nepodařilo se uložit');
                }
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ...switch (async) {
              AsyncData(:final value) => [
                  for (final c in value)
                    ListTile(
                      dense: true,
                      shape: AppShapes.md,
                      leading: Icon(c.bookIds.contains(book.id) ? Symbols.check_rounded : Symbols.collections_bookmark_rounded),
                      title: Text(c.title),
                      subtitle: Text('${c.bookIds.length} ${c.bookIds.length == 1 ? 'kniha' : (c.bookIds.length < 5 && c.bookIds.isNotEmpty ? 'knihy' : 'knih')}'),
                      onTap: c.bookIds.contains(book.id)
                          ? null
                          : () async {
                              try {
                                await addToCollection(ref, c.id, book.id);
                                showToast(messenger, 'Přidáno do sbírky „${c.title}“');
                              } catch (_) {
                                showToast(messenger, 'Nepodařilo se uložit');
                              }
                              if (context.mounted) Navigator.of(context).pop();
                            },
                    ),
                ],
              AsyncError() => [const Padding(padding: EdgeInsets.all(AppSpacing.sm), child: Text('Sbírky se nepodařilo načíst.'))],
              _ => [const Padding(padding: EdgeInsets.all(AppSpacing.sm), child: LinearProgressIndicator(minHeight: 2))],
            },
          ],
        ),
      ),
    );
  }
}

/// Řada sbírek nahoře v Knihovně knih (jen když nějaké jsou).
class SpokenCollectionsRail extends ConsumerWidget {
  const SpokenCollectionsRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(spokenCollectionsProvider).valueOrNull ?? const <SpokenCollection>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) {
          final c = list[i];
          return SizedBox(
            width: 130,
            child: MediaCard(
              title: c.title,
              subtitle: '${c.bookIds.length} ${c.bookIds.length == 1 ? 'kniha' : (c.bookIds.length < 5 && c.bookIds.isNotEmpty ? 'knihy' : 'knih')}',
              imageUrl: c.coverUrl,
              placeholderIcon: Symbols.collections_bookmark_rounded,
              onTap: () => context.push('/spoken/collection/${c.id}'),
            ),
          );
        },
      ),
    );
  }
}

/// Jedna sbírka: knihy v pořadí přidání, přejmenovat / smazat, odebrat knihu.
class SpokenCollectionScreen extends ConsumerWidget {
  const SpokenCollectionScreen({super.key, required this.collectionId});
  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final collections = ref.watch(spokenCollectionsProvider);
    final books = ref.watch(spokenBooksProvider).valueOrNull ?? const <SpokenBook>[];
    final c = collections.valueOrNull?.where((x) => x.id == collectionId).firstOrNull;
    final byId = {for (final b in books) b.id: b};
    final list = [for (final id in c?.bookIds ?? const <String>[]) if (byId[id] != null) byId[id]!];
    final messenger = ScaffoldMessenger.maybeOf(context);
    return Scaffold(
      appBar: SectionAppBar(c?.title ?? 'Sbírka', actions: [
        if (c != null)
          IconButton(
            icon: const Icon(Symbols.more_horiz_rounded, semanticLabel: 'Možnosti'),
            tooltip: 'Možnosti',
            onPressed: () => showGlassSheet<void>(
              context,
              builder: (sheet) => GlassSheet(
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Symbols.edit_rounded),
                        title: const Text('Přejmenovat'),
                        onTap: () async {
                          Navigator.of(sheet).pop();
                          final title = await _askTitle(context, initial: c.title, title: 'Přejmenovat sbírku');
                          if (title == null || title.isEmpty) return;
                          await ref.read(apiClientProvider).putJson('/spoken/collections/${c.id}', body: {'title': title});
                          ref.invalidate(spokenCollectionsProvider);
                        },
                      ),
                      ListTile(
                        leading: Icon(Symbols.delete_rounded, color: theme.colorScheme.error),
                        title: Text('Smazat sbírku', style: TextStyle(color: theme.colorScheme.error)),
                        subtitle: const Text('Knihy zůstanou'),
                        onTap: () async {
                          Navigator.of(sheet).pop();
                          await ref.read(apiClientProvider).deleteJson('/spoken/collections/${c.id}');
                          ref.invalidate(spokenCollectionsProvider);
                          showToast(messenger, 'Sbírka smazána (knihy zůstaly)');
                          if (context.mounted) context.pop();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ]),
      body: collections.isLoading && c == null
          ? const LoadingState()
          : c == null
              ? const EmptyState(icon: Symbols.collections_bookmark_rounded, message: 'Sbírka neexistuje.')
              : list.isEmpty
                  ? const EmptyState(
                      icon: Symbols.collections_bookmark_rounded,
                      message: 'Sbírka je prázdná. Knihu přidáš podržením a „Přidat do sbírky…“.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
                      children: [
                        for (final b in list)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox.square(
                              dimension: 56,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(AppRadii.xs),
                                child: ArtworkImage(url: b.coverUrl, icon: Symbols.menu_book_rounded),
                              ),
                            ),
                            title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [if (b.byline.isNotEmpty) b.byline, formatHours(b.durationMs)].where((s) => s.isNotEmpty).join(' · '),
                              style: muted,
                            ),
                            trailing: IconButton(
                              tooltip: 'Odebrat ze sbírky',
                              icon: const Icon(Symbols.remove_circle_rounded),
                              onPressed: () => removeFromCollection(ref, c.id, b.id),
                            ),
                            onTap: () => context.push('/spoken/book/${b.id}'),
                            onLongPress: b.canPlay ? () async => playBook(ref, await ref.read(spokenBookProvider(b.id).future)) : null,
                          ),
                      ],
                    ),
    );
  }
}
