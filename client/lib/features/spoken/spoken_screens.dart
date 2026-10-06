import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/app_mode.dart';
import '../../state/library_scope.dart';
import '../library/local_library_screen.dart' show LibraryScopeToggle;
import '../library/offline_tab.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_search_field.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surface_card.dart';
import '../../widgets/toast.dart';
import '../../widgets/glass/glass_segmented_control.dart';
import 'podcast_data.dart';
import 'podcast_screens.dart';
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
    // Podcasty jsou na Domů navíc -- jejich chyba nesmí schovat knihy.
    final podcasts = ref.watch(podcastHomeProvider).valueOrNull;
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
          final working = [for (final b in books) if (b.isWorking || b.status == 'failed') b];
          final shelf = [for (final b in books) if (b.isReady && b.progress == null) b].take(6).toList();
          final newEpisodes =
              (podcasts?.latest ?? const <PodcastEpisodeItem>[]).where((e) => !e.finished && !e.started).take(5).toList();
          // Rozposlouchané knihy i epizody dohromady, naposledy poslouchané první.
          final continuing = <_Continue>[
            for (final b in books)
              if (b.isReady && b.inProgress) _Continue(book: b, at: b.progress?.updatedAt),
            for (final e in podcasts?.inProgress ?? const <PodcastEpisodeItem>[])
              _Continue(episode: e, at: e.listenedAt),
          ]..sort((a, b) => (b.at ?? DateTime(2000)).compareTo(a.at ?? DateTime(2000)));
          final hasPodcasts = podcasts != null && (podcasts.inProgress.isNotEmpty || podcasts.latest.isNotEmpty);
          if (books.isEmpty && !hasPodcasts) {
            return ListView(children: [
              const SizedBox(height: 80),
              EmptyState(
                icon: Symbols.menu_book_rounded,
                message: 'Zatím tu nic není. V Hledání najdeš audioknihy i podcasty.',
                action: GlassButton(
                  label: 'Hledat',
                  icon: Symbols.search_rounded,
                  onPressed: () => context.go('/search'),
                ),
              ),
            ]);
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(spokenBooksProvider);
              ref.invalidate(podcastHomeProvider);
            },
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
              children: [
                if (continuing.isNotEmpty) ...[
                  const _Heading('Pokračovat'),
                  _ContinueCard(item: continuing.first),
                ],
                if (continuing.length > 1) ...[
                  const _Heading('Rozposlouchané'),
                  for (final c in continuing.skip(1))
                    if (c.book != null)
                      _BookTile(book: c.book!)
                    else
                      PodcastEpisodeTile(episode: c.episode!, showShowTitle: true),
                ],
                if (newEpisodes.isNotEmpty) ...[
                  const _Heading('Nové díly'),
                  for (final e in newEpisodes) PodcastEpisodeTile(episode: e, showShowTitle: true),
                ],
                if (shelf.isNotEmpty) ...[
                  const _Heading('Tvoje knihy'),
                  _BookShelf(books: shelf),
                ],
                if (working.isNotEmpty) ...[
                  const _Heading('Stahuje se'),
                  for (final b in working) _BookTile(book: b),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Rozposlouchaná kniha nebo epizoda (Domů › Pokračovat / Rozposlouchané).
class _Continue {
  const _Continue({this.book, this.episode, this.at});
  final SpokenBook? book;
  final PodcastEpisodeItem? episode;
  final DateTime? at;
}

/// Velká karta "Pokračovat" -- to, co jsi poslouchal naposledy.
class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({required this.item});
  final _Continue item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final book = item.book;
    final ep = item.episode;
    final title = book != null ? book.title : ep!.title;
    final cover = book != null ? book.coverUrl : ep!.artworkUrl;
    final dur = ep?.durationMs;
    final subtitle = book != null
        ? book.byline
        : [
            if (ep!.showTitle != null) ep.showTitle!,
            if (dur != null) 'zbývá ${formatHours(dur - ep.positionMs)}',
          ].join(' · ');
    Future<void> play() async {
      if (book != null) {
        playBook(ref, await ref.read(spokenBookProvider(book.id).future));
      } else {
        playEpisode(ref, ep!);
      }
    }

    return SurfaceCard(
      child: Row(
        children: [
          _Cover(url: cover, size: 96),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                ],
                if (ep != null && dur != null && dur > 0) ...[
                  const SizedBox(height: AppSpacing.xs),
                  LinearProgressIndicator(value: (ep.positionMs / dur).clamp(0.0, 1.0), minHeight: 4),
                ],
                const SizedBox(height: AppSpacing.sm),
                GlassButton(
                  label: 'Pokračovat',
                  icon: Symbols.play_arrow_rounded,
                  style: GlassButtonStyle.prominent,
                  compact: true,
                  onPressed: () => unawaited(play()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Polička obalů: připravené knihy, které jsi ještě nezačal.
class _BookShelf extends StatelessWidget {
  const _BookShelf({required this.books});
  final List<SpokenBook> books;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        final size = (constraints.maxWidth - AppSpacing.sm * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final b in books)
              SizedBox(
                width: size,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  onTap: () => context.push('/spoken/book/${b.id}'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Cover(url: b.coverUrl, size: size),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
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
    final kind = ref.watch(spokenKindProvider);
    final books = kind == SpokenKind.books;
    return Scaffold(
      appBar: const SectionAppBar('Hledat', actions: [AppModeToggle()]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
            child: GlassSearchField(
              controller: _controller,
              hintText: books ? 'Kniha, autor, kdo čte…' : 'Název podcastu nebo odkaz na YouTube kanál…',
              onSubmitted: (q) => setState(() => _query = q.trim()),
              onCleared: () => setState(() => _query = ''),
            ),
          ),
          const _KindSwitch(),
          Expanded(
            child: _query.length < 2
                ? EmptyState(
                    icon: books ? Symbols.menu_book_rounded : Symbols.podcasts_rounded,
                    message: books
                        ? 'Hledá se v českých a slovenských audioknihách. Stažení začne až po klepnutí na Stáhnout.'
                        : 'Hledá se v katalogu podcastů. Pořad, který je jen na YouTube, přidáš vložením odkazu na kanál.',
                  )
                : books
                    ? _Results(query: _query)
                    : PodcastSearchResults(query: _query),
          ),
        ],
      ),
    );
  }
}

/// Audioknihy / Podcasty -- stejný přepínač v Hledání i Knihovně.
class _KindSwitch extends ConsumerWidget {
  const _KindSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
        child: GlassSegmentedControl<SpokenKind>(
          segments: const [
            GlassSegment(value: SpokenKind.books, label: 'Audioknihy'),
            GlassSegment(value: SpokenKind.podcasts, label: 'Podcasty'),
          ],
          selected: ref.watch(spokenKindProvider),
          onChanged: (k) => ref.read(spokenKindProvider.notifier).state = k,
        ),
      );
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
    final kind = ref.watch(spokenKindProvider);
    final async = ref.watch(spokenBooksProvider);
    final booksView = async.when(
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
                    AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
                children: [for (final b in books) _BookTile(book: b)],
              ),
            ),
    );
    // Stejný rozsah jako hudební Knihovna; Offline = epizody v zařízení.
    final offline = ref.watch(libraryScopeProvider) == LibraryScope.offline;
    return Scaffold(
      appBar: const SectionAppBar('Knihovna', actions: [LibraryScopeToggle(), AppModeToggle()]),
      body: offline
          ? const OfflineTab(episodes: true)
          : Column(
              children: [
                const SizedBox(height: AppSpacing.xs),
                const _KindSwitch(),
                Expanded(child: kind == SpokenKind.books ? booksView : const MyPodcastsList()),
              ],
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
