import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart' show ApiException;
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/app_mode.dart';
import '../../state/library_scope.dart';
import '../library/local_library_screen.dart' show LibraryScopeToggle;
import '../library/offline_tab.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_search_field.dart';
import '../../widgets/media_card.dart' show ArtworkImage, MediaCard;
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import '../../widgets/glass/glass_segmented_control.dart';
import '../../widgets/glass/glass_sheet.dart';
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
      'downloading' => 'Stahuje se · ${(b.downloadProgress * 100).round()} %'
          '${b.playableFiles > 0 ? ' · už jde poslouchat' : ''}',
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
      trailing: book.canPlay
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
          final shelf = [for (final b in books) if (b.isReady && b.progress == null) b].take(20).toList();
          final newEpisodes =
              (podcasts?.latest ?? const <PodcastEpisodeItem>[]).where((e) => !e.finished && !e.started).take(15).toList();
          final shows = ref.watch(myPodcastsProvider).valueOrNull ?? const <PodcastShowItem>[];
          // Doporučení se načítají zvlášť -- Domů na ně nečeká.
          final recs = ref.watch(spokenRecommendationsProvider).valueOrNull;
          // Rozposlouchané knihy i epizody dohromady, naposledy poslouchané první.
          final continuing = <_Continue>[
            for (final b in books)
              if (b.isReady && b.inProgress) _Continue(book: b, at: b.progress?.updatedAt),
            for (final e in podcasts?.inProgress ?? const <PodcastEpisodeItem>[])
              _Continue(episode: e, at: e.listenedAt),
          ]..sort((a, b) => (b.at ?? DateTime(2000)).compareTo(a.at ?? DateTime(2000)));
          final hasPodcasts = podcasts != null && (podcasts.inProgress.isNotEmpty || podcasts.latest.isNotEmpty);
          final hasRecs = recs != null && (recs.books.isNotEmpty || recs.podcasts.isNotEmpty);
          if (books.isEmpty && !hasPodcasts && !hasRecs) {
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
            // Sekce jako na hudebním Domů: nadpis a vodorovná řada karet.
            child: ListView(
              padding: EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.lg + navBottomInset(context)),
              children: [
                if (continuing.isNotEmpty) ...[
                  const SectionHeader('Pokračovat'),
                  _Rail(children: [for (final c in continuing) _ContinueCard(item: c)]),
                ],
                if (newEpisodes.isNotEmpty) ...[
                  const SectionHeader('Nové díly'),
                  _Rail(children: [
                    for (final e in newEpisodes)
                      MediaCard(
                        title: e.title,
                        subtitle: [e.showTitle ?? '', episodeDate(e.publishedAt, DateTime.now())]
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        imageUrl: e.artworkUrl,
                        placeholderIcon: Symbols.podcasts_rounded,
                        onTap: () => playEpisode(ref, e),
                      ),
                  ]),
                ],
                if (shelf.isNotEmpty) ...[
                  const SectionHeader('Tvoje knihy'),
                  _Rail(children: [
                    for (final b in shelf)
                      MediaCard(
                        title: b.title,
                        subtitle: b.author ?? formatHours(b.durationMs),
                        imageUrl: b.coverUrl,
                        placeholderIcon: Symbols.menu_book_rounded,
                        onTap: () => context.push('/spoken/book/${b.id}'),
                      ),
                  ]),
                ],
                if (shows.isNotEmpty) ...[
                  const SectionHeader('Tvoje pořady'),
                  _Rail(children: [
                    for (final s in shows)
                      MediaCard(
                        title: s.title,
                        subtitle: s.author,
                        imageUrl: s.artworkUrl,
                        placeholderIcon: Symbols.podcasts_rounded,
                        onTap: () => context.push('/podcasts/show/${s.id}'),
                      ),
                  ]),
                ],
                if (recs != null && recs.books.isNotEmpty) ...[
                  const SectionHeader('Doporučené knihy'),
                  _Rail(children: [
                    for (final b in recs.books)
                      MediaCard(
                        title: b.release.title,
                        subtitle: b.reason,
                        imageUrl: b.release.coverUrl,
                        placeholderIcon: Symbols.menu_book_rounded,
                        // Rovnou obsah vydání (co by se stáhlo).
                        onTap: () => _download(context, ref, b.release),
                      ),
                  ]),
                ],
                if (recs != null && recs.podcasts.isNotEmpty) ...[
                  const SectionHeader('Doporučené podcasty'),
                  _Rail(children: [
                    for (final p in recs.podcasts)
                      MediaCard(
                        title: p.show.title,
                        subtitle: p.reason,
                        imageUrl: p.show.artworkUrl,
                        placeholderIcon: Symbols.podcasts_rounded,
                        onTap: () async {
                          try {
                            final id = await openPodcast(ref, p.show);
                            if (context.mounted) unawaited(context.push('/podcasts/show/$id'));
                          } catch (_) {
                            if (context.mounted) toast(context, 'Pořad se nepodařilo otevřít');
                          }
                        },
                      ),
                  ]),
                ],
                if (working.isNotEmpty) ...[
                  const SectionHeader('Stahuje se'),
                  _Rail(children: [
                    for (final b in working)
                      MediaCard(
                        title: b.title,
                        subtitle: _statusLine(b),
                        artwork: _ProgressArt(
                          url: b.coverUrl,
                          value: b.status == 'downloading' ? b.downloadProgress : null,
                        ),
                        onTap: () => context.push('/spoken/book/${b.id}'),
                      ),
                  ]),
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

/// Karta "Pokračovat": kniha nebo epizoda s pruhem průběhu; klepnutí
/// pokračuje od uloženého místa, dlouhý stisk otevře detail.
class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({required this.item});
  final _Continue item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = item.book;
    final ep = item.episode;
    final dur = ep?.durationMs;
    return MediaCard(
      title: book != null ? book.title : ep!.title,
      subtitle: book != null
          ? (book.author ?? book.byline)
          : (dur != null ? 'zbývá ${formatHours(dur - ep!.positionMs)}' : ep!.showTitle),
      artwork: _ProgressArt(
        url: book != null ? book.coverUrl : ep!.artworkUrl,
        value: ep != null && dur != null && dur > 0 ? (ep.positionMs / dur).clamp(0.0, 1.0) : null,
        icon: book != null ? Symbols.menu_book_rounded : Symbols.podcasts_rounded,
      ),
      onTap: () async {
        if (book != null) {
          playBook(ref, await ref.read(spokenBookProvider(book.id).future));
        } else {
          playEpisode(ref, ep!);
        }
      },
      onLongPress: book != null ? () => context.push('/spoken/book/${book.id}') : null,
    );
  }
}

/// Obal karty s tenkým pruhem průběhu dole (poslech / stahování).
class _ProgressArt extends StatelessWidget {
  const _ProgressArt({required this.url, required this.value, this.icon = Symbols.menu_book_rounded});
  final String? url;
  final double? value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          ArtworkImage(url: url, icon: icon),
          if (value != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: LinearProgressIndicator(value: value, minHeight: 4),
            ),
        ],
      );
}

/// Vodorovná řada karet jako na hudebním Domů.
class _Rail extends StatelessWidget {
  const _Rail({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 200,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          itemCount: children.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, i) => SizedBox(width: 140, child: children[i]),
        ),
      );
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
  void initState() {
    super.initState();
    // "Jiná verze" z detailu knihy: hledat rovnou její název.
    final request = ref.read(spokenSearchRequestProvider);
    if (request != null) {
      _apply(request);
      Future.microtask(() => ref.read(spokenSearchRequestProvider.notifier).state = null);
    }
  }

  void _apply(String q) {
    _controller.text = q;
    _query = q;
    ref.read(spokenKindProvider.notifier).state = SpokenKind.books;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(spokenSearchRequestProvider, (_, q) {
      if (q == null) return;
      setState(() => _apply(q));
      ref.read(spokenSearchRequestProvider.notifier).state = null;
    });
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
    final czech = ref.watch(spokenSearchProvider(query));
    // Záloha (Soulseek, typicky anglicky) se načítá zvlášť -- je pomalejší.
    final foreign = ref.watch(spokenForeignSearchProvider(query));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final cz = czech.valueOrNull;
    final other = foreign.valueOrNull ?? const <SpokenRelease>[];
    if (czech.isLoading && foreign.isLoading) return const LoadingState();
    if (cz != null && cz.releases.isEmpty && !foreign.isLoading && other.isEmpty) {
      return const EmptyState(icon: Symbols.menu_book_rounded, message: 'Nic se nenašlo – ani česky, ani v jiných jazycích.');
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
      children: [
        const _Heading('Česky'),
        if (czech.isLoading)
          const Padding(padding: EdgeInsets.all(AppSpacing.sm), child: LinearProgressIndicator(minHeight: 2))
        else if (czech.hasError)
          Text('České hledání se nepovedlo.', style: muted)
        else if (cz!.releases.isEmpty)
          Text('Česká verze se nenašla.', style: muted)
        else ...[
          if (!cz.loginConfigured)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text('Stažení se rozjede, až bude na serveru nastavený účet SkTorrent.', style: muted),
            ),
          for (final r in cz.releases) _ReleaseTile(release: r),
        ],
        const _Heading('Anglicky a další jazyky'),
        if (foreign.isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text('Hledám na Soulseeku…', style: muted),
          )
        else if (foreign.hasError)
          Text('Hledání na Soulseeku se nepovedlo.', style: muted)
        else if (other.isEmpty)
          Text('Nic se nenašlo.', style: muted)
        else
          for (final r in other) _ReleaseTile(release: r),
      ],
    );
  }
}

/// Jedno vydání knihy (SkTorrent i Soulseek stejně).
class _ReleaseTile extends ConsumerWidget {
  const _ReleaseTile({required this.release});
  final SpokenRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = release;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      // Klepnutí = obsah vydání (co přesně by se stáhlo).
      onTap: r.bookId != null ? () => context.push('/spoken/book/${r.bookId}') : () => _download(context, ref, r),
      leading: _Cover(url: r.coverUrl),
      title: Text(r.title, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          formatSize(r.sizeBytes),
          if (r.files != null) '${r.files} souborů',
          r.seeders > 0 ? '${r.seeders} zdrojů' : 'teď nikdo nesdílí',
        ].where((s) => s.isNotEmpty).join(' · '),
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
              onPressed: () => _download(context, ref, r),
            ),
    );
  }
}

/// Stáhnout vydání: vždy nejdřív jeho obsah (složky a soubory), stahuje se
/// až tlačítkem v něm. Sbírka (víc složek) = výběr knih / kapitol -- každá
/// vybraná složka je v knihovně samostatná kniha.
Future<void> _download(BuildContext context, WidgetRef ref, SpokenRelease r) async {
  try {
    final groups = await fetchReleaseGroups(ref, r);
    if (!context.mounted) return;
    if (groups.isEmpty) {
      toast(context, 'Ve vydání není žádný zvuk');
      return;
    }
    await showGlassSheet<void>(context, builder: (_) => GlassSheet(child: CollectionPickSheet(release: r, groups: groups)));
  } catch (e) {
    if (context.mounted) {
      toast(
        context,
        '$e'.contains('SKTORRENT')
            ? 'Chybí přihlášení na SkTorrent'
            : '$e'.contains('vypršel')
                ? 'Výsledek hledání vypršel, vyhledej knihu znovu'
                : 'Obsah vydání se nepodařilo načíst',
      );
    }
  }
}

class CollectionPickSheet extends ConsumerStatefulWidget {
  const CollectionPickSheet({super.key, required this.release, required this.groups});
  final SpokenRelease release;
  final List<ReleaseGroup> groups;

  @override
  ConsumerState<CollectionPickSheet> createState() => CollectionPickSheetState();
}

class CollectionPickSheetState extends ConsumerState<CollectionPickSheet> {
  final Set<int> _selected = {};
  final Set<String> _expanded = {};
  bool _busy = false;

  /// Jedna kniha: rovnou rozbalená a celá vybraná.
  bool get _single => widget.groups.length == 1;

  /// Soulseek stahuje celou složku (výběr souborů jen u torrentu).
  bool get _selectable => widget.release.source != 'slskd';

  bool get _everything => widget.groups.every((g) => g.files.every((f) => _selected.contains(f.index)));

  @override
  void initState() {
    super.initState();
    if (_single || !_selectable) {
      for (final g in widget.groups) {
        _expanded.add(g.folder);
        _selected.addAll(g.files.map((f) => f.index));
      }
    }
  }

  int get _bytes => [
        for (final g in widget.groups)
          for (final f in g.files)
            if (_selected.contains(f.index)) f.size,
      ].fold(0, (a, b) => a + b);

  void _toggleGroup(ReleaseGroup g, bool on) => setState(() {
        for (final f in g.files) {
          on ? _selected.add(f.index) : _selected.remove(f.index);
        }
      });

  Future<void> _submit() async {
    setState(() => _busy = true);
    var books = 0;
    try {
      // Celé vydání jako jedna kniha (stejná jako dřív bez výběru).
      if ((_single && _everything) || !_selectable) {
        await acquireSpoken(ref, widget.release);
        if (mounted) {
          Navigator.of(context).pop();
          toast(context, 'Kniha se stahuje – najdeš ji na Domů');
        }
        return;
      }
      for (final g in widget.groups) {
        final picked = [for (final f in g.files) if (_selected.contains(f.index)) f.index];
        if (picked.isEmpty) continue;
        final size = [for (final f in g.files) if (_selected.contains(f.index)) f.size].fold(0, (a, b) => a + b);
        await acquireSpoken(ref, widget.release, files: picked, folder: g.folder, sizeBytes: size);
        books++;
      }
      if (mounted) {
        Navigator.of(context).pop();
        toast(context, books == 1 ? 'Kniha se stahuje – najdeš ji na Domů' : 'Stahuje se $books knih – najdeš je na Domů');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, e is ApiException && e.detail != null ? e.detail! : 'Stažení se nepodařilo spustit');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_single ? 'Obsah' : 'Co stáhnout?', style: theme.textTheme.titleMedium),
                Text(
                  _single
                      ? '${widget.release.title} · ${widget.groups.first.files.length} souborů · '
                          '${formatSize(widget.groups.first.size)}'
                      : '${widget.release.title} je sbírka. Vyber knihy, nebo jen některé části.',
                  style: muted,
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final g in widget.groups) ...[
                  CheckboxListTile(
                    value: g.files.every((f) => _selected.contains(f.index))
                        ? true
                        : (g.files.any((f) => _selected.contains(f.index)) ? null : false),
                    tristate: true,
                    onChanged: _selectable ? (v) => _toggleGroup(g, !g.files.every((f) => _selected.contains(f.index))) : null,
                    title: Text(g.folder.isEmpty ? widget.release.title : g.folder),
                    subtitle: Text('${formatSize(g.size)} · ${g.files.length} částí', style: muted),
                    secondary: IconButton(
                      tooltip: _expanded.contains(g.folder) ? 'Skrýt části' : 'Vybrat jednotlivé části',
                      icon: Icon(_expanded.contains(g.folder) ? Symbols.expand_less_rounded : Symbols.expand_more_rounded),
                      onPressed: () => setState(
                        () => _expanded.contains(g.folder) ? _expanded.remove(g.folder) : _expanded.add(g.folder),
                      ),
                    ),
                  ),
                  if (_expanded.contains(g.folder))
                    for (final f in g.files)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.lg),
                        child: CheckboxListTile(
                          dense: true,
                          value: _selected.contains(f.index),
                          onChanged: _selectable
                              ? (v) => setState(() => v == true ? _selected.add(f.index) : _selected.remove(f.index))
                              : null,
                          title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(formatSize(f.size), style: muted),
                        ),
                      ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: GlassButton(
              label: _selected.isEmpty
                  ? 'Vyber, co stáhnout'
                  : _everything
                      ? 'Stáhnout (${formatSize(_bytes)})'
                      : 'Stáhnout vybrané (${formatSize(_bytes)})',
              icon: Symbols.download_rounded,
              style: GlassButtonStyle.prominent,
              expand: true,
              onPressed: _selected.isEmpty || _busy ? null : _submit,
            ),
          ),
        ],
      ),
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
              if (book.status == 'failed') ...[
                const SizedBox(height: AppSpacing.md),
                _FailedActions(book: book),
              ],
              if (book.status == 'downloading') ...[
                const SizedBox(height: AppSpacing.xs),
                LinearProgressIndicator(value: book.downloadProgress, minHeight: 4),
              ],
              const SizedBox(height: AppSpacing.md),
              // I během stahování -- první kapitola je k dispozici hned.
              if (book.files.isNotEmpty)
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

/// Stažení selhalo: znovu, jiná verze (hledání s názvem knihy), nebo pryč.
class _FailedActions extends ConsumerWidget {
  const _FailedActions({required this.book});
  final SpokenBook book;

  /// "55-Heir to the Empire" -> "Heir to the Empire" (+ autor, je-li).
  String get _query {
    final title = book.title.replaceFirst(RegExp(r'^\d+\s*[-.]\s*'), '').replaceAll(RegExp(r'[\[(].*?[\])]'), '').trim();
    return [title, if (book.author != null) book.author!].join(' ');
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        showToast(ScaffoldMessenger.maybeOf(context), 'Nepodařilo se, zkus to znovu.');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Wrap(
        alignment: WrapAlignment.center,
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          GlassButton(
            label: 'Zkusit znovu',
            icon: Symbols.refresh_rounded,
            style: GlassButtonStyle.prominent,
            onPressed: () => _run(context, () => retrySpokenBook(ref, book.id)),
          ),
          GlassButton(
            label: 'Jiná verze',
            icon: Symbols.search_rounded,
            onPressed: () {
              ref.read(spokenSearchRequestProvider.notifier).state = _query;
              context.go('/search');
            },
          ),
          GlassButton(
            label: 'Odebrat',
            icon: Symbols.delete_rounded,
            style: GlassButtonStyle.plain,
            onPressed: () => _run(context, () async {
              await removeSpokenBook(ref, book.id);
              if (context.mounted) context.pop();
            }),
          ),
        ],
      );
}

String _clock(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}
