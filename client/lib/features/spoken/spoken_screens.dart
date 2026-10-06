import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/app_mode.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_search_field.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import 'spoken_data.dart';

/// Režim mluveného slova (audioknihy) -- Domů, Hledání, Knihovna a detail
/// knihy. Přehrávač je společný s hudbou; poslech knih se nikam nepočítá.

void playBook(WidgetRef ref, SpokenBook book, {int? fileIndex, Duration? position}) {
  final queue = spokenQueue(book);
  if (queue.isEmpty) return;
  var index = fileIndex ?? 0;
  var start = position;
  final p = book.progress;
  if (fileIndex == null && p != null && !p.finished) {
    final i = book.files.indexWhere((f) => f.id == p.fileId);
    if (i >= 0) {
      index = i;
      start = Duration(milliseconds: p.positionMs);
    }
  }
  unawaited(ref.read(audioPlayerControllerProvider.notifier).playQueue(
        queue,
        index,
        sourceLabel: book.title,
        startPosition: start,
        rememberProgress: false,
        context: (route: '/spoken/book/${book.id}'),
      ));
}

String _statusLine(SpokenBook b) => switch (b.status) {
      'pending' => b.error ?? 'Ve frontě ke stažení',
      'downloading' => 'Stahuje se · ${(b.downloadProgress * 100).round()} %',
      'importing' => 'Připravuje se…',
      'failed' => 'Nepodařilo se: ${b.error ?? 'neznámá chyba'}',
      _ => [formatHours(b.durationMs), if (b.byline.isNotEmpty) b.byline].where((s) => s.isNotEmpty).join(' · '),
    };

class _Cover extends StatelessWidget {
  const _Cover({required this.url, this.size = 56});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size > 100 ? AppRadii.xl : AppRadii.xs),
          child: ArtworkImage(url: url, icon: Symbols.menu_book_rounded, iconSize: size / 2.4),
        ),
      );
}

class _BookTile extends ConsumerWidget {
  const _BookTile({required this.book});
  final SpokenBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _Cover(url: book.coverUrl),
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_statusLine(book), style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (book.status == 'downloading')
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: LinearProgressIndicator(value: book.downloadProgress, minHeight: 3),
            ),
        ],
      ),
      trailing: book.isReady
          ? GlassIconButton(
              icon: Symbols.play_arrow_rounded,
              tooltip: book.inProgress ? 'Pokračovat' : 'Přehrát',
              style: GlassButtonStyle.tonal,
              size: 40,
              onPressed: () async {
                // Seznam souborů má jen detail.
                final full = await ref.read(spokenBookProvider(book.id).future);
                playBook(ref, full);
              },
            )
          : null,
      onTap: () => context.push('/spoken/book/${book.id}'),
    );
  }
}

// --- Domů -------------------------------------------------------------------

class SpokenHomeScreen extends ConsumerWidget {
  const SpokenHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spokenBooksProvider);
    return Scaffold(
      appBar: const SectionAppBar('Mluvené slovo', actions: [AppModeToggle()]),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Knihy se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenBooksProvider),
        ),
        data: (books) {
          final listening = [for (final b in books) if (b.isReady && b.inProgress) b];
          final working = [for (final b in books) if (b.isWorking || b.status == 'failed') b];
          final fresh = [for (final b in books) if (b.isReady && b.progress == null) b].take(10).toList();
          if (books.isEmpty) {
            return ListView(children: [
              const SizedBox(height: 80),
              EmptyState(
                icon: Symbols.menu_book_rounded,
                message: 'Zatím tu nejsou žádné knihy. Najdi audioknihu v Hledání a stáhni ji.',
                action: GlassButton(
                  label: 'Hledat audioknihy',
                  icon: Symbols.search_rounded,
                  onPressed: () => context.go('/search'),
                ),
              ),
            ]);
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(spokenBooksProvider),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
              children: [
                if (listening.isNotEmpty) ...[
                  const _Heading('Rozposlouchané'),
                  for (final b in listening) _BookTile(book: b),
                ],
                if (working.isNotEmpty) ...[
                  const _Heading('Stahuje se'),
                  for (final b in working) _BookTile(book: b),
                ],
                if (fresh.isNotEmpty) ...[
                  const _Heading('Nově přidané'),
                  for (final b in fresh) _BookTile(book: b),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xxs),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

// --- Hledání ----------------------------------------------------------------

class SpokenSearchScreen extends ConsumerStatefulWidget {
  const SpokenSearchScreen({super.key});

  @override
  ConsumerState<SpokenSearchScreen> createState() => _SpokenSearchScreenState();
}

class _SpokenSearchScreenState extends ConsumerState<SpokenSearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SectionAppBar('Hledat audioknihy', actions: [AppModeToggle()]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
            child: GlassSearchField(
              controller: _controller,
              hintText: 'Kniha, autor, kdo čte…',
              onSubmitted: (q) => setState(() => _query = q.trim()),
              onCleared: () => setState(() => _query = ''),
            ),
          ),
          Expanded(
            child: _query.length < 2
                ? const EmptyState(
                    icon: Symbols.menu_book_rounded,
                    message: 'Hledá se v českých a slovenských audioknihách. Stažení začne až po klepnutí na Stáhnout.',
                  )
                : _Results(query: _query),
          ),
        ],
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spokenSearchProvider(query));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return async.when(
      loading: () => const LoadingState(),
      error: (e, _) => ErrorState(
        message: 'Hledání se nepovedlo.',
        error: e,
        onRetry: () => ref.invalidate(spokenSearchProvider(query)),
      ),
      data: (result) {
        if (result.releases.isEmpty) return const EmptyState(icon: Symbols.menu_book_rounded, message: 'Nic se nenašlo.');
        return ListView(
          padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
          children: [
            if (!result.loginConfigured)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text('Stažení se rozjede, až bude na serveru nastavený účet SkTorrent.', style: muted),
              ),
            for (final r in result.releases)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _Cover(url: r.coverUrl),
                title: Text(r.title, maxLines: 3, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [formatSize(r.sizeBytes), r.seeders > 0 ? '${r.seeders} zdrojů' : 'teď nikdo nesdílí']
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: muted,
                ),
                trailing: r.bookId != null
                    ? GlassButton(
                        label: r.status == 'ready' ? 'Otevřít' : 'Stahuje se',
                        compact: true,
                        onPressed: () => context.push('/spoken/book/${r.bookId}'),
                      )
                    : GlassButton(
                        label: 'Stáhnout',
                        icon: Symbols.download_rounded,
                        compact: true,
                        style: GlassButtonStyle.prominent,
                        onPressed: () async {
                          try {
                            await acquireSpoken(ref, r);
                            if (context.mounted) toast(context, 'Kniha se stahuje – najdeš ji na Domů');
                          } catch (e) {
                            if (context.mounted) toast(context, 'Stažení se nepodařilo spustit');
                          }
                        },
                      ),
              ),
          ],
        );
      },
    );
  }
}

// --- Knihovna ---------------------------------------------------------------

class SpokenLibraryScreen extends ConsumerWidget {
  const SpokenLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spokenBooksProvider);
    return Scaffold(
      appBar: const SectionAppBar('Audioknihy', actions: [AppModeToggle()]),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Knihy se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenBooksProvider),
        ),
        data: (books) => books.isEmpty
            ? const EmptyState(icon: Symbols.menu_book_rounded, message: 'Knihovna audioknih je zatím prázdná.')
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(spokenBooksProvider),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
                  children: [for (final b in books) _BookTile(book: b)],
                ),
              ),
      ),
    );
  }
}

// --- Detail knihy -----------------------------------------------------------

class SpokenBookScreen extends ConsumerWidget {
  const SpokenBookScreen({super.key, required this.bookId});
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spokenBookProvider(bookId));
    final playing = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId));
    return Scaffold(
      appBar: const SectionAppBar(''),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Knihu se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenBookProvider(bookId)),
        ),
        data: (book) {
          final theme = Theme.of(context);
          final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
          return ListView(
            padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
            children: [
              Center(child: _Cover(url: book.coverUrl, size: 220)),
              const SizedBox(height: AppSpacing.md),
              Text(book.title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
              if (book.byline.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xxs),
                Text(book.byline, style: muted, textAlign: TextAlign.center),
              ],
              const SizedBox(height: AppSpacing.xxs),
              Text(
                book.isReady
                    ? [formatHours(book.durationMs), formatSize(book.sizeBytes)].where((s) => s.isNotEmpty).join(' · ')
                    : _statusLine(book),
                style: muted,
                textAlign: TextAlign.center,
              ),
              if (book.status == 'downloading') ...[
                const SizedBox(height: AppSpacing.xs),
                LinearProgressIndicator(value: book.downloadProgress, minHeight: 4),
              ],
              const SizedBox(height: AppSpacing.md),
              if (book.isReady && book.files.isNotEmpty)
                Center(
                  child: GlassButton(
                    label: book.inProgress ? 'Pokračovat' : 'Přehrát',
                    icon: Symbols.play_arrow_rounded,
                    style: GlassButtonStyle.prominent,
                    onPressed: () => playBook(ref, book),
                  ),
                ),
              if (book.files.length > 1 || (book.files.isNotEmpty && book.files.first.chapters.length > 1)) ...[
                const SizedBox(height: AppSpacing.lg),
                Text('Obsah', style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xxs),
                for (final (i, f) in book.files.indexed)
                  if (f.chapters.length > 1)
                    for (final c in f.chapters)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(c.title),
                        trailing: Text(_clock(c.startMs), style: muted),
                        onTap: () => playBook(ref, book, fileIndex: i, position: Duration(milliseconds: c.startMs)),
                      )
                  else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      selected: playing == spokenQueueId(book.id, f.id),
                      title: Text(f.title ?? 'Část ${i + 1}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Text(formatHours(f.durationMs), style: muted),
                      onTap: () => playBook(ref, book, fileIndex: i, position: Duration.zero),
                    ),
              ],
              if (!book.isReady) ...[
                const SizedBox(height: AppSpacing.md),
                Text(book.releaseTitle, style: muted, textAlign: TextAlign.center),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _clock(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}
