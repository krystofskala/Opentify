import 'dart:async';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/cz_plural.dart';
import '../../core/api_client.dart' show ApiException;
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/app_mode.dart';
import '../../state/library_scope.dart';
import '../library/local_library_screen.dart' show LibraryScopeToggle;
import '../library/offline_tab.dart';
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/detail_hero.dart' show HeroTeaser;
import '../../widgets/glass/glass_search_field.dart';
import '../../widgets/media_card.dart' show ArtworkImage, MediaCard;
import '../../widgets/net_image.dart' show NetImage;
import '../../widgets/sort_button.dart';
import '../../widgets/view_mode_toggle.dart';
import '../../widgets/edge_fade_scroll.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import '../../widgets/glass/glass_segmented_control.dart';
import '../../widgets/glass/glass_sheet.dart';
import 'podcast_data.dart';
import 'podcast_screens.dart';
import 'spoken_actions.dart';
import 'spoken_data.dart';
import 'spoken_heart.dart';

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
    // Od začátku výslovně (0) -- přehrávač se pak na pozici neptá serveru.
    startPosition: start ?? Duration.zero,
    rememberProgress: false,
    context: (route: '/spoken/book/${book.id}'),
    // Náhodné pořadí / opakování z hudby do knihy nepatří (díly by hrály
    // napřeskáčku a vypnout nešlo -- místo tlačítek je ±30 s; audit 8. 10.).
    shuffle: false,
    repeatMode: RepeatMode.off,
  ));
}

String _statusLine(SpokenBook b) => switch (b.status) {
      'pending' => b.error ?? 'Ve frontě ke stažení',
      'downloading' => 'Stahuje se · ${(b.downloadProgress * 100).round()} %'
          '${b.playableFiles > 0 ? ' · už jde poslouchat' : ''}',
      'importing' => 'Připravuje se…',
      'failed' => 'Nepodařilo se: ${b.error ?? 'neznámá chyba'}',
      _ => [formatHours(b.durationMs), if (b.byline.isNotEmpty) b.byline, if (b.seriesLine != null) b.seriesLine!]
          .where((s) => s.isNotEmpty)
          .join(' · '),
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
      onLongPress: () => showSpokenBookActions(context, book),
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
        // Nové načtení (průběh stahování) nechá vidět původní obsah -- jinak bliklo načítání.
        skipLoadingOnReload: true,
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Knihy se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenBooksProvider),
        ),
        data: (books) {
          final working = [
            for (final b in books)
              if (b.isWorking || b.status == 'failed') b
          ];
          final shelf = [
            for (final b in books)
              if (b.isReady && b.mine && b.progress == null && !b.isDrama) b
          ].take(20).toList();
          // Rozhlasové hry zvlášť od audioknih -- moje i ostatních.
          final dramas = [
            for (final b in books)
              if (b.isReady && b.isDrama) b
          ].take(20).toList();
          // Knihy, které už na serveru stáhl někdo jiný -- pustit hned, bez
          // dalšího stahování (uživatel 7. 10.).
          final others = [
            for (final b in books)
              if (b.isReady && !b.mine && !b.isDrama) b
          ].take(20).toList();
          // Pořadí a skryté sekce podle profilu (Upravit Domů mluveného slova).
          final layout = ref.watch(spokenHomeLayoutProvider).valueOrNull;
          List<Widget> ordered(Map<String, List<Widget>> sections) {
            if (layout == null) return [for (final w in sections.values) ...w];
            return [
              for (final e in layout)
                if (e.visible) ...?sections[e.id],
            ];
          }

          // Volitelná sekce (vypnutá, zapíná se v Upravit Domů): načíst jen když je zapnutá.
          final nextOn = layout?.any((e) => e.id == 'next_in_series' && e.visible) ?? false;
          final nextParts = nextOn ? ref.watch(spokenNextInSeriesProvider).valueOrNull ?? const <SpokenNextPart>[] : const <SpokenNextPart>[];
          final newEpisodes = (podcasts?.latest ?? const <PodcastEpisodeItem>[])
              .where((e) => !e.finished && !e.started)
              .take(15)
              .toList();
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
              ref.invalidate(spokenHomeLayoutProvider);
              ref.invalidate(spokenNextInSeriesProvider);
            },
            // Sekce jako na hudebním Domů: nadpis a vodorovná řada karet.
            child: ListView(
              padding: EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.lg + navBottomInset(context)),
              children: [
                ...ordered(<String, List<Widget>>{
                  if (continuing.isNotEmpty)
                    'continue': [
                      const SectionHeader('Pokračovat'),
                      _Rail(children: [for (final c in continuing) _ContinueCard(item: c)]),
                    ],
                  if (newEpisodes.isNotEmpty)
                    'new_episodes': [
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
                  if (shows.isNotEmpty)
                    'shows': [
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
                  if (recs != null && recs.podcasts.isNotEmpty)
                    'rec_podcasts': [
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
                  if (shelf.isNotEmpty)
                    'my_books': [
                      const SectionHeader('Tvoje knihy'),
                      _Rail(children: [
                        for (final b in shelf)
                          MediaCard(
                            title: b.title,
                            subtitle: b.author ?? formatHours(b.durationMs),
                            imageUrl: b.coverUrl,
                            placeholderIcon: Symbols.menu_book_rounded,
                            onTap: () => context.push('/spoken/book/${b.id}'),
                            onLongPress: () => showSpokenBookActions(context, b),
                          ),
                      ]),
                    ],
                  if (recs != null && recs.books.isNotEmpty)
                    'rec_books': [
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
                  if (others.isNotEmpty)
                    'others_books': [
                      const SectionHeader('Knihy ostatních'),
                      _Rail(children: [
                        for (final b in others)
                          MediaCard(
                            title: b.title,
                            subtitle: b.author ?? formatHours(b.durationMs),
                            imageUrl: b.coverUrl,
                            placeholderIcon: Symbols.menu_book_rounded,
                            onTap: () => context.push('/spoken/book/${b.id}'),
                            onLongPress: () => showSpokenBookActions(context, b),
                          ),
                      ]),
                    ],
                  if (dramas.isNotEmpty)
                    'dramas': [
                      const SectionHeader('Rozhlasové hry'),
                      _Rail(children: [
                        for (final b in dramas)
                          MediaCard(
                            title: b.title,
                            subtitle: b.author ?? formatHours(b.durationMs),
                            imageUrl: b.coverUrl,
                            placeholderIcon: Symbols.theater_comedy_rounded,
                            onTap: () => context.push('/spoken/book/${b.id}'),
                            onLongPress: () => showSpokenBookActions(context, b),
                          ),
                      ]),
                    ],
                  if (nextParts.isNotEmpty)
                    'next_in_series': [
                      const SectionHeader('Další díl řady'),
                      _Rail(children: [
                        for (final n in nextParts)
                          MediaCard(
                            title: n.title,
                            subtitle: '${n.seriesName} · díl ${n.number == n.number.roundToDouble() ? n.number.toInt() : n.number}'
                                '${n.bookId == null ? ' · ke stažení' : ''}',
                            imageUrl: n.coverUrl,
                            placeholderIcon: Symbols.format_list_numbered_rounded,
                            onTap: () => context.push(n.bookId != null
                                ? '/spoken/book/${n.bookId}'
                                : spokenWorkPath(n.title, n.author ?? '')),
                          ),
                      ]),
                    ],
                  if (working.isNotEmpty)
                    'downloading': [
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
                            onLongPress: () => showSpokenBookActions(context, b),
                          ),
                      ]),
                    ],
                }),
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
                        ? 'Hledá se v českých a slovenských audioknihách a v archivu Českého rozhlasu (četba, '
                            'rozhlasové hry). Audioknihu nebo hru z YouTube přidáš vložením odkazu na video. '
                            'Stažení začne až po klepnutí na Stáhnout.'
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
    // Co už je na serveru (autoři, knihy) -- rychlé, zobrazí se hned nahoře.
    final local = ref.watch(spokenLocalSearchProvider(query)).valueOrNull;
    // Záloha (Soulseek, typicky anglicky) se načítá zvlášť -- je pomalejší.
    final foreign = ref.watch(spokenForeignSearchProvider(query));
    // Archiv Českého rozhlasu (četba, hry) -- taky zvlášť.
    final rozhlas = ref.watch(spokenRozhlasSearchProvider(query));
    final radio = rozhlas.valueOrNull ?? const <SpokenRelease>[];
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final cz = czech.valueOrNull;
    final other = foreign.valueOrNull ?? const <SpokenRelease>[];
    if (czech.isLoading && foreign.isLoading) return const LoadingState();
    final hasLocal = local != null && (local.books.isNotEmpty || local.people.isNotEmpty);
    if (cz != null &&
        cz.releases.isEmpty &&
        !foreign.isLoading &&
        other.isEmpty &&
        !rozhlas.isLoading &&
        radio.isEmpty &&
        !hasLocal) {
      return const EmptyState(
          icon: Symbols.menu_book_rounded, message: 'Nic se nenašlo – ani česky, ani v jiných jazycích.');
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
      children: [
        if (local != null && local.people.isNotEmpty) ...[
          const _Heading('Autoři a interpreti'),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: local.people.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.xs),
              itemBuilder: (context, i) {
                final p = local.people[i];
                return _PersonChip(name: p.name, role: p.role, books: p.books, image: p.image);
              },
            ),
          ),
        ],
        if (local != null && local.books.isNotEmpty) ...[
          const _Heading('Na serveru'),
          for (final b in local.books)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _Cover(url: b.coverUrl),
              title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [if (b.byline.isNotEmpty) b.byline, if (b.isReady) formatHours(b.durationMs) else _statusLine(b)]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
                style: muted,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => context.push('/spoken/book/${b.id}'),
              onLongPress: () => showSpokenBookActions(context, b),
            ),
        ],
        _Heading(cz != null && cz.releases.isNotEmpty && cz.releases.every((r) => r.isYoutube) ? 'Z YouTube' : 'Česky'),
        if (czech.isLoading)
          const Padding(padding: EdgeInsets.all(AppSpacing.sm), child: LinearProgressIndicator(minHeight: 2))
        else if (czech.hasError)
          // Stejně jako detail knihy: důvod a Zkusit znovu (UX audit 7. 10.).
          ErrorState(
            message: 'České hledání se nepovedlo.',
            error: czech.error,
            compact: true,
            onRetry: () => ref.invalidate(spokenSearchProvider(query)),
          )
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
        const _Heading('Český rozhlas'),
        if (rozhlas.isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text('Hledám v archivu rozhlasu…', style: muted),
          )
        else if (rozhlas.hasError)
          Text('Archiv Českého rozhlasu teď neodpovídá.', style: muted)
        else if (radio.isEmpty)
          Text('Nic, co by teď šlo poslouchat.', style: muted)
        else
          for (final r in radio) _ReleaseTile(release: r),
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
        r.isRozhlas
            ? [
                r.uploader ?? 'Český rozhlas',
                if (r.kind == 'drama') 'rozhlasová hra',
                if (r.durationText != null) r.durationText!,
                // Seriál, ze kterého jde stáhnout jen část (práva vypršela).
                if (!r.complete && r.totalParts != null) 'jen ${r.files} z ${r.totalParts} dílů',
              ].join(' · ')
            : r.isYoutube
            ? ['YouTube', if (r.uploader != null) r.uploader!, if (r.durationText != null) r.durationText!].join(' · ')
            : [
                formatSize(r.sizeBytes),
                if (r.files != null) czCount(r.files!, 'soubor', 'soubory', 'souborů'),
                r.seeders > 0 ? czCount(r.seeders, 'zdroj', 'zdroje', 'zdrojů') : 'teď nikdo nesdílí',
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
    await showGlassSheet<void>(context,
        builder: (_) => GlassSheet(child: CollectionPickSheet(release: r, groups: groups)));
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

  /// Soulseek a rozhlas stahují celé vydání (výběr souborů jen u torrentu).
  bool get _selectable => widget.release.source != 'slskd' && widget.release.source != 'rozhlas';

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

  static const _waitingText = 'Požádal jsem správce o schválení – po schválení se kniha objeví v knihovně';

  Future<void> _submit() async {
    setState(() => _busy = true);
    var books = 0;
    var waiting = 0; // čeká na schválení správcem
    try {
      // Celé vydání jako jedna kniha (stejná jako dřív bez výběru).
      if ((_single && _everything) || !_selectable) {
        final started = await acquireSpoken(ref, widget.release);
        if (mounted) {
          Navigator.of(context).pop();
          toast(context, started ? 'Kniha se stahuje – najdeš ji na Domů' : _waitingText);
        }
        return;
      }
      for (final g in widget.groups) {
        final picked = [
          for (final f in g.files)
            if (_selected.contains(f.index)) f.index
        ];
        if (picked.isEmpty) continue;
        final size = [
          for (final f in g.files)
            if (_selected.contains(f.index)) f.size
        ].fold(0, (a, b) => a + b);
        if (await acquireSpoken(ref, widget.release, files: picked, folder: g.folder, sizeBytes: size)) {
          books++;
        } else {
          waiting++;
        }
      }
      if (mounted) {
        Navigator.of(context).pop();
        toast(
          context,
          waiting > 0
              ? _waitingText
              : books == 1
                  ? 'Kniha se stahuje – najdeš ji na Domů'
                  : '${czPlural(books, 'Stahuje', 'Stahují', 'Stahuje')} se ${czCount(books, 'kniha', 'knihy', 'knih')} – najdeš je na Domů',
        );
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
                      ? '${widget.release.title} · ${czCount(widget.groups.first.files.length, 'soubor', 'soubory', 'souborů')} · '
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
                    onChanged:
                        _selectable ? (v) => _toggleGroup(g, !g.files.every((f) => _selected.contains(f.index))) : null,
                    title: Text(g.folder.isEmpty ? widget.release.title : g.folder),
                    subtitle: Text('${formatSize(g.size)} · ${g.files.length} částí', style: muted),
                    secondary: IconButton(
                      tooltip: _expanded.contains(g.folder) ? 'Skrýt části' : 'Vybrat jednotlivé části',
                      icon: Icon(
                          _expanded.contains(g.folder) ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
                          semanticLabel: _expanded.contains(g.folder) ? 'Skrýt části' : 'Vybrat jednotlivé části'),
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
        // Nové načtení (průběh stahování) nechá vidět původní obsah -- jinak bliklo načítání.
        skipLoadingOnReload: true,
      loading: () => const LoadingState(),
      error: (e, _) => ErrorState(
        message: 'Knihy se nepodařilo načíst.',
        error: e,
        onRetry: () => ref.invalidate(spokenBooksProvider),
      ),
      data: (books) => books.isEmpty
          ? const EmptyState(icon: Symbols.menu_book_rounded, message: 'Knihovna audioknih je zatím prázdná.')
          : _BooksLibrary(books: books),
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

/// Řazení knih v Knihovně (jako u hudby).
enum _BookSort { recent, added, title, author, length }

const _bookSortLabels = {
  _BookSort.recent: 'Naposledy poslouchané',
  _BookSort.added: 'Přidáno',
  _BookSort.title: 'Název',
  _BookSort.author: 'Autor',
  _BookSort.length: 'Délka',
};

final _bookSortProvider = StateProvider<_BookSort>((ref) => _BookSort.recent);
final _bookViewProvider = StateProvider<ViewMode>((ref) => ViewMode.list);
final _bookFilterProvider = StateProvider<String?>((ref) => null); // null | listening | finished | drama

/// Knihovna audioknih jako hudební: hledání, řazení, filtr, seznam / karty.
/// Rozsah (Moje / Stažené / Vše) je společný s hudbou (`LibraryScopeToggle`).
class _BooksLibrary extends ConsumerStatefulWidget {
  const _BooksLibrary({required this.books});
  final List<SpokenBook> books;

  @override
  ConsumerState<_BooksLibrary> createState() => _BooksLibraryState();
}

class _BooksLibraryState extends ConsumerState<_BooksLibrary> {
  String _query = '';

  static String _fold(String text) => text.toLowerCase();

  List<SpokenBook> _visible(LibraryScope scope, _BookSort sort, String? filter) {
    final words = _fold(_query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    var books = widget.books.where((b) {
      if (scope == LibraryScope.mine && !b.mine) return false;
      if (filter == 'listening' && !b.inProgress) return false;
      if (filter == 'finished' && !(b.progress?.finished ?? false)) return false;
      if (filter == 'drama' && !b.isDrama) return false;
      if (words.isEmpty) return true;
      final text = _fold([b.title, b.author ?? '', b.narrator ?? ''].join(' '));
      return words.every(text.contains);
    }).toList();
    int byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    DateTime old = DateTime(2000);
    switch (sort) {
      case _BookSort.recent:
        books.sort((a, b) => (b.progress?.updatedAt ?? b.createdAt ?? old).compareTo(a.progress?.updatedAt ?? a.createdAt ?? old));
      case _BookSort.added:
        books.sort((a, b) => (b.createdAt ?? old).compareTo(a.createdAt ?? old));
      case _BookSort.title:
        books.sort((a, b) => byText(a.title, b.title));
      case _BookSort.author:
        // U autora řady pohromadě a podle dílů (Zaklínač 1, 2, 3…).
        books.sort((a, b) {
          final byAuthor = byText(a.author ?? '~', b.author ?? '~');
          if (byAuthor != 0) return byAuthor;
          final bySeries = byText(a.seriesName ?? '~', b.seriesName ?? '~');
          if (bySeries != 0) return bySeries;
          return (a.seriesNumber ?? 999).compareTo(b.seriesNumber ?? 999);
        });
      case _BookSort.length:
        books.sort((a, b) => (b.durationMs ?? 0).compareTo(a.durationMs ?? 0));
    }
    return books;
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(libraryScopeProvider);
    final sort = ref.watch(_bookSortProvider);
    final view = ref.watch(_bookViewProvider);
    final filter = ref.watch(_bookFilterProvider);
    final books = _visible(scope, sort, filter);
    final bottom = AppSpacing.lg + navBottomInset(context);
    final header = [
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
        child: GlassSearchField(
          hintText: 'Hledat v knihovně',
          onChanged: (q) => setState(() => _query = q.trim()),
          onCleared: () => setState(() => _query = ''),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
        child: Row(
          children: [
            Expanded(
              child: EdgeFadeScroll(
                child: Row(
                  children: [
                    SortButton<_BookSort>(
                      value: sort,
                      labels: _bookSortLabels,
                      onChanged: (v) => ref.read(_bookSortProvider.notifier).state = v,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Rozposlouchané'),
                      selected: filter == 'listening',
                      onSelected: (on) => ref.read(_bookFilterProvider.notifier).state = on ? 'listening' : null,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Dočtené'),
                      selected: filter == 'finished',
                      onSelected: (on) => ref.read(_bookFilterProvider.notifier).state = on ? 'finished' : null,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Rozhlasové hry'),
                      selected: filter == 'drama',
                      onSelected: (on) => ref.read(_bookFilterProvider.notifier).state = on ? 'drama' : null,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            ViewModeToggle(mode: view, onChanged: (m) => ref.read(_bookViewProvider.notifier).state = m),
          ],
        ),
      ),
    ];
    final empty = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: EmptyState(
        icon: Symbols.menu_book_rounded,
        message: _query.isNotEmpty || filter != null
            ? 'Nic neodpovídá.'
            : 'Tvoje knihy tu budou, až nějakou stáhneš. Ostatní knihy na serveru ukáže rozsah „Vše“.',
      ),
    );
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(spokenBooksProvider),
      child: CustomScrollView(
        slivers: [
          SliverList(delegate: SliverChildListDelegate(header)),
          if (books.isEmpty)
            SliverToBoxAdapter(child: empty)
          else if (view == ViewMode.list)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, bottom),
              sliver: SliverList.builder(itemCount: books.length, itemBuilder: (_, i) => _BookTile(book: books[i])),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, bottom),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 0.72,
                ),
                itemCount: books.length,
                itemBuilder: (context, i) {
                  final b = books[i];
                  return MediaCard(
                    title: b.title,
                    subtitle: b.isReady ? (b.author ?? formatHours(b.durationMs)) : _statusLine(b),
                    imageUrl: b.coverUrl,
                    placeholderIcon: Symbols.menu_book_rounded,
                    onTap: () => context.push('/spoken/book/${b.id}'),
                    onLongPress: () => showSpokenBookActions(context, b),
                  );
                },
              ),
            ),
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
      appBar: SectionAppBar('', actions: [
        if (async.valueOrNull case final book?)
          IconButton(
            icon: const Icon(Symbols.more_horiz_rounded, semanticLabel: 'Možnosti'),
            tooltip: 'Možnosti',
            onPressed: () => showSpokenBookActions(context, book),
          ),
      ]),
      body: async.when(
        // Nové načtení (průběh stahování) nechá vidět původní obsah -- jinak bliklo načítání.
        skipLoadingOnReload: true,
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(child: Text(book.title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center)),
                  SpokenHeart(bookId: book.id),
                ],
              ),
              // Autor a interpret (čte) -- klepnutím jejich stránka.
              if (book.author != null || book.narrator != null) ...[
                const SizedBox(height: AppSpacing.xxs),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (book.author != null) _PersonLink(name: book.author!, style: muted),
                    if (book.author != null && book.narrator != null) Text(' · ', style: muted),
                    // "čte X" pohromadě (nezalomit mezi slovem a jménem); víc
                    // interpretů = "čtou" (Český rozhlas: "Čtou: A a B").
                    if (book.narrator != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(RegExp(r',| a ').hasMatch(book.narrator!) ? 'čtou ' : 'čte ', style: muted),
                          Flexible(child: _PersonLink(name: book.narrator!, style: muted, narrator: true)),
                        ],
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.xxs),
              Text(
                book.isReady
                    ? [formatHours(book.durationMs), formatSize(book.sizeBytes)].where((s) => s.isNotEmpty).join(' · ')
                    : _statusLine(book),
                style: muted,
                textAlign: TextAlign.center,
              ),
              // Druh: odhad z názvu / pořadu se může plést -- klepnutím přepnout.
              if (book.isReady) Center(child: _KindToggle(book: book)),
              // Popis knihy, když se najde jistě (Google Books).
              if (ref.watch(spokenBookDescriptionProvider(book.id)).valueOrNull case final description?) ...[
                const SizedBox(height: AppSpacing.sm),
                HeroTeaser(text: description),
              ],
              // Všechna vydání téhle knihy (jiní interpreti, nezkrácené…).
              if (book.author != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    GlassButton(
                      label: 'Všechna vydání',
                      icon: Symbols.library_books_rounded,
                      compact: true,
                      onPressed: () => context.push(spokenWorkPath(book.title, book.author!)),
                    ),
                    // Řada a pořadí čtení (Wikidata) -- jen když se najde.
                    _SeriesButton(title: book.title, author: book.author!),
                  ],
                ),
              ],
              if (book.status == 'failed') ...[
                const SizedBox(height: AppSpacing.md),
                _FailedActions(book: book),
              ],
              // Hotová kniha, které chybí díly (Český rozhlas): říct to a nabídnout dotažení.
              if (book.isReady && book.error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(book.error!, style: muted, textAlign: TextAlign.center),
                Center(
                  child: GlassButton(
                    label: 'Dotáhnout chybějící díly',
                    icon: Symbols.refresh_rounded,
                    compact: true,
                    onPressed: () async {
                      try {
                        await retrySpokenBook(ref, book.id);
                      } catch (_) {
                        if (context.mounted) toast(context, 'Nepodařilo se, zkus to znovu.');
                      }
                    },
                  ),
                ),
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

/// Stránka knihy: kniha z katalogu knihoven a všechna její vydání,
/// doporučené nahoře s důvodem. Nic se nepřiděluje, vybíráš ty.
class SpokenWorkScreen extends ConsumerWidget {
  const SpokenWorkScreen({super.key, required this.title, required this.author});
  final String title;
  final String author;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final who = (title: title, author: author);
    final async = ref.watch(spokenWorkProvider(who));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: const SectionAppBar(''),
      body: async.when(
        // Nové načtení (průběh stahování) nechá vidět původní obsah -- jinak bliklo načítání.
        skipLoadingOnReload: true,
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Knihu se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenWorkProvider(who)),
        ),
        data: (w) {
          if (w == null) {
            return const EmptyState(icon: Symbols.menu_book_rounded, message: 'Tuhle knihu katalog knihoven nezná.');
          }
          final recommended = w.editions.firstOrNull;
          final others = w.editions.skip(1).toList();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(spokenWorkProvider(who)),
            child: ListView(
              padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(w.title, style: theme.textTheme.headlineMedium),
                      if (w.author != null) _PersonLink(name: w.author!, style: muted),
                      Text(
                        [
                          if (w.seriesName != null)
                            w.seriesNumber != null ? '${w.seriesName} · díl ${w.seriesNumber}' : w.seriesName!,
                          if (w.year != null) 'poprvé vyšlo ${w.year}',
                        ].join(' · '),
                        style: muted,
                      ),
                    ],
                  ),
                ),
                if (w.author != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                    child: Align(alignment: Alignment.centerLeft, child: _SeriesButton(title: w.title, author: w.author!)),
                  ),
                if (w.summary != null) HeroTeaser(text: w.summary!),
                if (recommended != null) ...[
                  const SectionHeader('Doporučené vydání'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: _EditionTile(edition: recommended, highlighted: true),
                  ),
                ],
                if (others.isNotEmpty) ...[
                  const SectionHeader('Další vydání'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Column(children: [for (final e in others) _EditionTile(edition: e)]),
                  ),
                ],
                if (w.editions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.lg),
                    child: EmptyState(icon: Symbols.menu_book_rounded, message: 'Žádné vydání ke stažení jsme nenašli.'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Jedno vydání: na serveru = otevřít knihu, jinak obsah vydání a Stáhnout.
class _EditionTile extends ConsumerWidget {
  const _EditionTile({required this.edition, this.highlighted = false});
  final SpokenEdition edition;
  final bool highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final e = edition;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    void open() => e.onServer ? context.push('/spoken/book/${e.bookId}') : _download(context, ref, e.release);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: open,
      leading: _Cover(url: e.coverUrl, size: highlighted ? 64 : 56),
      title: Text(e.title, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(e.why.join(' · '), style: muted, maxLines: 3, overflow: TextOverflow.ellipsis),
      trailing: GlassButton(
        label: e.onServer ? (e.status == 'ready' ? 'Otevřít' : 'Stahuje se') : 'Stáhnout',
        icon: e.onServer ? null : Symbols.download_rounded,
        compact: true,
        style: highlighted ? GlassButtonStyle.prominent : GlassButtonStyle.tonal,
        onPressed: open,
      ),
    );
  }
}

/// Jméno autora / interpreta, které otevře jeho stránku.
class _PersonLink extends StatelessWidget {
  const _PersonLink({required this.name, this.style, this.narrator = false});
  final String name;
  final TextStyle? style;
  final bool narrator;

  @override
  Widget build(BuildContext context) => Semantics(
        link: true,
        label: narrator ? 'Interpret $name' : 'Autor $name',
        excludeSemantics: true,
        child: InkWell(
          onTap: () => context.push(spokenPersonPath(name, narrator: narrator)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            child: Text(
              name,
              style: style?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
}

/// Kulatá fotka autora / interpreta; bez fotky ikona.
class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({required this.url, this.size = 64});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Symbols.person_rounded, size: size * 0.45, color: scheme.onSurfaceVariant),
    );
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: url == null ? placeholder : NetImage(url: url!, placeholder: placeholder),
      ),
    );
  }
}

/// Autor / interpret ve výsledcích hledání -- fotka se dotáhne zvlášť.
class _PersonChip extends ConsumerWidget {
  const _PersonChip({required this.name, required this.role, required this.books, this.image});
  final String name;
  final String role;
  final int books;
  final String? image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final narrator = role == 'narrator';
    final url = image ?? ref.watch(spokenPersonImageProvider((name: name, role: role))).valueOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.sm),
      onTap: () => context.push(spokenPersonPath(name, narrator: narrator)),
      child: SizedBox(
        width: 104,
        child: Column(
          children: [
            _PersonAvatar(url: url, size: 88),
            const SizedBox(height: AppSpacing.xxs),
            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            Text(
              [narrator ? 'Interpret' : 'Autor', if (books > 0) czCount(books, 'kniha', 'knihy', 'knih')].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stránka autora / interpreta: knihy na serveru (pustit hned) a další
/// vydání na SkTorrentu ke stažení.
class SpokenPersonScreen extends ConsumerWidget {
  const SpokenPersonScreen({super.key, required this.name, this.narrator = false});
  final String name;
  final bool narrator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final who = (name: name, role: narrator ? 'narrator' : 'author');
    final async = ref.watch(spokenPersonProvider(who));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: const SectionAppBar(''),
      body: async.when(
        // Nové načtení (průběh stahování) nechá vidět původní obsah -- jinak bliklo načítání.
        skipLoadingOnReload: true,
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Stránku se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenPersonProvider(who)),
        ),
        data: (p) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(spokenPersonProvider(who)),
          child: ListView(
            padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fotka z Wikidat (jako u interpretů hudby), jen když sedí jméno i povolání.
                    if (p.image != null) ...[
                      _PersonAvatar(url: p.image, size: 140),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    Row(
                      children: [
                        Flexible(child: Text(p.name, style: theme.textTheme.headlineMedium)),
                        SpokenHeart(person: p.name, narrator: narrator),
                      ],
                    ),
                    if (p.description != null) Text(p.description!, style: muted),
                    Text(
                      [
                        narrator ? 'Interpret' : 'Autor',
                        if (p.books.isNotEmpty) '${czCount(p.books.length, 'kniha', 'knihy', 'knih')} na serveru',
                      ].join(' · '),
                      style: muted,
                    ),
                  ],
                ),
              ),
              if (p.bio != null) HeroTeaser(text: p.bio!),
              if (p.books.isNotEmpty) ...[
                const SectionHeader('Na serveru'),
                _Rail(children: [
                  for (final b in p.books)
                    MediaCard(
                      title: b.title,
                      subtitle: b.isReady ? formatHours(b.durationMs) : _statusLine(b),
                      imageUrl: b.coverUrl,
                      placeholderIcon: Symbols.menu_book_rounded,
                      onTap: () => context.push('/spoken/book/${b.id}'),
                      onLongPress: () => showSpokenBookActions(context, b),
                    ),
                ]),
              ],
              if (p.releases.isNotEmpty) ...[
                const SectionHeader('Ke stažení'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Column(children: [for (final r in p.releases) _ReleaseTile(release: r)]),
                ),
              ],
              if (p.books.isEmpty && p.releases.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.xl),
                  child: EmptyState(
                    icon: Symbols.menu_book_rounded,
                    message: 'Nic dalšího od tohohle jména jsme nenašli.',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Díl 3 · Sága o zaklínači" -- otevře řadu s pořadím čtení. Bez řady nic.
class _SeriesButton extends ConsumerWidget {
  const _SeriesButton({required this.title, required this.author});
  final String title;
  final String author;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(spokenSeriesProvider((title: title, author: author))).valueOrNull;
    if (s == null || s.name.isEmpty) return const SizedBox.shrink();
    final part = spokenSeriesPartOf(s, title);
    return GlassButton(
      label: part?.number != null ? 'Díl ${_partNumber(part!.number!)} · ${s.name}' : s.name,
      icon: Symbols.format_list_numbered_rounded,
      compact: true,
      onPressed: () => context.push(spokenSeriesPath(title, author)),
    );
  }
}

String _partNumber(num n) => n == n.roundToDouble() ? '${n.toInt()}' : '$n'.replaceAll('.', ',');

/// Řada a pořadí čtení: díly v pořadí (u každého, co je na serveru a jak
/// daleko jsi), díla mimo pořadí a celá řada ke stažení (komplety).
class SpokenSeriesScreen extends ConsumerWidget {
  const SpokenSeriesScreen({super.key, required this.title, required this.author});
  final String title;
  final String author;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final who = (title: title, author: author);
    final async = ref.watch(spokenSeriesProvider(who));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: const SectionAppBar(''),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Řadu se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenSeriesProvider(who)),
        ),
        data: (s) {
          if (s == null) {
            return const EmptyState(icon: Symbols.format_list_numbered_rounded, message: 'Řada knihy se nenašla.');
          }
          final current = spokenSeriesPartOf(s, title);
          final done = s.parts.where((p) => p.state == 'finished').length;
          final collections = s.name.isEmpty
              ? null
              : ref.watch(spokenSeriesCollectionsProvider((name: s.name, author: s.author))).valueOrNull;
          return ListView(
            padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name.isEmpty ? title : s.name, style: theme.textTheme.headlineMedium),
                    _PersonLink(name: s.author, style: muted),
                    Text(
                      [
                        czCount(s.parts.length, 'díl', 'díly', 'dílů'),
                        if (done > 0) 'dočteno $done',
                        'pořadí podle vydání',
                      ].join(' · '),
                      style: muted,
                    ),
                  ],
                ),
              ),
              const SectionHeader('Pořadí čtení'),
              for (final p in s.parts) _SeriesPartTile(part: p, author: s.author, current: identical(p, current)),
              if (s.loose.isNotEmpty) ...[
                const SectionHeader('Mimo pořadí'),
                for (final p in s.loose) _SeriesPartTile(part: p, author: s.author),
              ],
              if (collections != null && collections.isNotEmpty) ...[
                const SectionHeader('Celá řada ke stažení'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Column(children: [for (final r in collections) _ReleaseTile(release: r)]),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SeriesPartTile extends StatelessWidget {
  const _SeriesPartTile({required this.part, required this.author, this.current = false});
  final SpokenSeriesPart part;
  final String author;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final state = switch (part.state) {
      'finished' => 'dočteno',
      'listening' => 'rozposloucháno',
      'ready' => 'na serveru',
      'downloading' => 'stahuje se',
      _ => null,
    };
    return ListTile(
      selected: current,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: part.number != null
            ? Text(_partNumber(part.number!), style: theme.textTheme.labelLarge)
            : Icon(Symbols.more_horiz_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
      ),
      title: Text(part.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if (part.year != null) '${part.year}', state ?? 'najít vydání'].join(' · '),
        style: muted,
      ),
      trailing: Icon(
        switch (part.state) {
          'finished' => Symbols.check_circle_rounded,
          'listening' || 'ready' => Symbols.play_circle_rounded,
          'downloading' => Symbols.downloading_rounded,
          _ => Symbols.chevron_right_rounded,
        },
        color: part.state == null ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary,
      ),
      // Na serveru -> kniha; jinak stránka knihy se všemi vydáními ke stažení.
      onTap: () => context.push(part.bookId != null ? '/spoken/book/${part.bookId}' : spokenWorkPath(part.title, author)),
    );
  }
}

/// Audiokniha / rozhlasová hra -- ruční přepnutí (platí pro všechny profily).
class _KindToggle extends ConsumerWidget {
  const _KindToggle({required this.book});
  final SpokenBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
        icon: Icon(book.isDrama ? Symbols.theater_comedy_rounded : Symbols.menu_book_rounded, size: 18),
        label: Text(book.isDrama ? 'Rozhlasová hra' : 'Audiokniha'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () async {
          final next = book.isDrama ? 'book' : 'drama';
          try {
            await setSpokenKind(ref, book.id, next);
            if (context.mounted) {
              toast(context, next == 'drama' ? 'Přesunuto mezi rozhlasové hry' : 'Přesunuto mezi audioknihy');
            }
          } catch (_) {
            if (context.mounted) toast(context, 'Nepodařilo se uložit');
          }
        },
      );
}

/// Stažení selhalo: znovu, jiná verze (hledání s názvem knihy), nebo pryč.
class _FailedActions extends ConsumerWidget {
  const _FailedActions({required this.book});
  final SpokenBook book;

  /// "55-Heir to the Empire" -> "Heir to the Empire" (+ autor, je-li).
  String get _query {
    final title =
        book.title.replaceFirst(RegExp(r'^\d+\s*[-.]\s*'), '').replaceAll(RegExp(r'[\[(].*?[\])]'), '').trim();
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
