import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import 'podcast_data.dart';
import 'podcast_offline.dart';
import 'spoken_data.dart' show formatHours;

/// Podcasty v režimu mluveného slova: pořad s epizodami, výsledky hledání,
/// odebírané pořady a sekce na Domů. Epizoda hraje sama (jako skladba
/// z hledání), od místa, kde jsi skončil.

void playEpisode(WidgetRef ref, PodcastEpisodeItem ep, {String? showId}) {
  unawaited(ref.read(audioPlayerControllerProvider.notifier).playQueue(
        [ep.toQueueItem()],
        0,
        sourceLabel: ep.showTitle,
        startPosition: ep.started ? Duration(milliseconds: ep.positionMs) : null,
        rememberProgress: false,
        context: (route: showId == null ? null : '/podcasts/show/$showId'),
      ));
}

class _Art extends StatelessWidget {
  const _Art({required this.url, this.size = 56});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size > 100 ? AppRadii.xl : AppRadii.xs),
          child: ArtworkImage(url: url, icon: Symbols.podcasts_rounded, iconSize: size / 2.4),
        ),
      );
}

class PodcastEpisodeTile extends ConsumerWidget {
  const PodcastEpisodeTile({super.key, required this.episode, this.showId, this.showShowTitle = false});
  final PodcastEpisodeItem episode;
  final String? showId;
  final bool showShowTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final playing = ref.watch(audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId)) == 'pc:${episode.id}';
    final dur = episode.durationMs;
    final left = episode.started && dur != null ? 'zbývá ${formatHours(dur - episode.positionMs)}' : formatHours(dur);
    final meta = [
      if (showShowTitle && episode.showTitle != null) episode.showTitle!,
      episodeDate(episode.publishedAt, DateTime.now()),
      if (episode.finished) 'přehráno' else left,
    ].where((s) => s.isNotEmpty).join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: playing,
      leading: showShowTitle ? _Art(url: episode.artworkUrl, size: 48) : null,
      title: Text(
        episode.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: episode.finished ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta, style: muted),
          if (episode.started && dur != null && dur > 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: LinearProgressIndicator(value: (episode.positionMs / dur).clamp(0.0, 1.0), minHeight: 3),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DownloadButton(episodeId: episode.id),
          Icon(
            episode.finished ? Symbols.check_circle_rounded : Symbols.play_circle_rounded,
            color: theme.colorScheme.primary,
          ),
        ],
      ),
      onTap: () => playEpisode(ref, episode, showId: showId),
    );
  }
}

/// Stáhnout epizodu do zařízení / smazat ji odtud.
class _DownloadButton extends ConsumerWidget {
  const _DownloadButton({required this.episodeId});
  final String episodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(podcastOfflineProvider);
    final saved = offline.saved.contains(episodeId);
    if (offline.downloading.contains(episodeId)) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.sm),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final ctrl = ref.read(podcastOfflineProvider.notifier);
    return IconButton(
      tooltip: saved ? 'Smazat z telefonu' : 'Stáhnout do telefonu',
      icon: Icon(saved ? Symbols.download_done_rounded : Symbols.download_rounded, size: 22),
      onPressed: () async {
        if (saved) {
          await ctrl.remove(episodeId);
          if (context.mounted) toast(context, 'Epizoda smazána z telefonu');
          return;
        }
        final ok = await ctrl.download(episodeId);
        if (context.mounted) toast(context, ok ? 'Epizoda je v telefonu – hraje i bez internetu' : 'Stažení se nepovedlo');
      },
    );
  }
}

/// Výsledky hledání podcastů (Hledání mluveného slova).
class PodcastSearchResults extends ConsumerWidget {
  const PodcastSearchResults({super.key, required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(podcastSearchProvider(query));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return async.when(
      loading: () => const LoadingState(),
      error: (e, _) => ErrorState(
        message: 'Hledání se nepovedlo.',
        error: e,
        onRetry: () => ref.invalidate(podcastSearchProvider(query)),
      ),
      data: (shows) => shows.isEmpty
          ? const EmptyState(icon: Symbols.podcasts_rounded, message: 'Nic se nenašlo.')
          : ListView(
              padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
              children: [
                for (final s in shows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _Art(url: s.artworkUrl),
                    title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text([s.author ?? '', if (s.subscribed) 'odebíráš'].where((x) => x.isNotEmpty).join(' · '),
                        style: muted),
                    trailing: const Icon(Symbols.chevron_right_rounded),
                    onTap: () async {
                      try {
                        final id = await openPodcast(ref, s);
                        if (context.mounted) unawaited(context.push('/podcasts/show/$id'));
                      } catch (_) {
                        if (context.mounted) toast(context, 'Pořad se nepodařilo otevřít');
                      }
                    },
                  ),
              ],
            ),
    );
  }
}

/// Odebírané pořady (Knihovna mluveného slova).
class MyPodcastsList extends ConsumerWidget {
  const MyPodcastsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myPodcastsProvider);
    final fromSpotify = ref.watch(podcastHistoryProvider).valueOrNull ?? const [];
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // Nabídka pořadů ze Spotify historie -- jen odkaz, nic se samo neodebírá.
    final historyRow = fromSpotify.isEmpty
        ? null
        : ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Symbols.history_rounded),
            title: const Text('Poslouchal jsi na Spotify'),
            subtitle: Text('${fromSpotify.length} pořadů – vyber, co odebírat', style: muted),
            trailing: const Icon(Symbols.chevron_right_rounded),
            onTap: () => context.push('/podcasts/history'),
          );
    return async.when(
      loading: () => const LoadingState(),
      error: (e, _) => ErrorState(
        message: 'Pořady se nepodařilo načíst.',
        error: e,
        onRetry: () => ref.invalidate(myPodcastsProvider),
      ),
      data: (shows) => shows.isEmpty && historyRow == null
          ? const EmptyState(
              icon: Symbols.podcasts_rounded,
              message: 'Zatím nic neodebíráš. Najdi podcast v Hledání a dej Odebírat.',
            )
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(myPodcastsProvider);
                ref.invalidate(podcastHistoryProvider);
              },
              child: ListView(
                padding:
                    EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
                children: [
                  if (historyRow != null) historyRow,
                  for (final s in shows)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: _Art(url: s.artworkUrl),
                      title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: s.author == null ? null : Text(s.author!, style: muted),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: () => context.push('/podcasts/show/${s.id}'),
                    ),
                ],
              ),
            ),
    );
  }
}

/// "Poslouchal jsi na Spotify": pořady z importované historie, u každého
/// Odebírat. Nic se neodebírá samo (uživatel si vybere).
class PodcastHistoryScreen extends ConsumerWidget {
  const PodcastHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(podcastHistoryProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: const SectionAppBar('Poslouchal jsi na Spotify'),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Historii se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(podcastHistoryProvider),
        ),
        data: (items) {
          final pending = items.where((i) => i.pending).length;
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(podcastHistoryProvider),
            child: ListView(
              padding:
                  EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
              children: [
                Text(
                  'Pořady z tvé historie ze Spotify, nejposlouchanější nahoře. Po odběru se epizody, '
                  'které jsi tam doposlouchal, označí jako přehrané.'
                  '${pending > 0 ? ' Ještě dohledávám $pending pořadů – stáhni dolů pro obnovení.' : ''}',
                  style: muted,
                ),
                const SizedBox(height: AppSpacing.xs),
                for (final i in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _Art(url: i.artworkUrl),
                    title: Text(i.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        formatHours(i.listenedMs),
                        '${i.episodes} ${i.episodes == 1 ? 'epizoda' : (i.episodes < 5 ? 'epizody' : 'epizod')}',
                        if (i.lastPlayedAt != null) 'naposledy ${i.lastPlayedAt!.year}',
                        if (!i.found && !i.pending) 'jen na Spotify',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: muted,
                    ),
                    trailing: i.pending
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : !i.found
                            ? null
                            : i.subscribed
                                ? GlassButton(
                                    label: 'Odebíráš',
                                    compact: true,
                                    onPressed: i.showId == null ? null : () => context.push('/podcasts/show/${i.showId}'),
                                  )
                                : GlassButton(
                                    label: 'Odebírat',
                                    compact: true,
                                    style: GlassButtonStyle.prominent,
                                    onPressed: () async {
                                      try {
                                        final marked = await subscribeFromHistory(ref, i);
                                        if (context.mounted) {
                                          toast(context, marked > 0 ? 'Odebíráš · $marked epizod označeno jako přehrané' : 'Odebíráš');
                                        }
                                      } catch (_) {
                                        if (context.mounted) toast(context, 'Odběr se nepodařil');
                                      }
                                    },
                                  ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Sekce podcastů na Domů mluveného slova (rozposlouchané, nové epizody).
List<Widget> podcastHomeSections(BuildContext context, PodcastHome home, Widget Function(String) heading) => [
      if (home.inProgress.isNotEmpty) ...[
        heading('Rozposlouchané epizody'),
        for (final e in home.inProgress) PodcastEpisodeTile(episode: e, showShowTitle: true),
      ],
      if (home.latest.isNotEmpty) ...[
        heading('Nové epizody'),
        for (final e in home.latest.where((e) => !e.finished && !e.started).take(10))
          PodcastEpisodeTile(episode: e, showShowTitle: true),
      ],
    ];

class PodcastShowScreen extends ConsumerWidget {
  const PodcastShowScreen({super.key, required this.showId});
  final String showId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(podcastShowProvider(showId));
    return Scaffold(
      appBar: const SectionAppBar(''),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Pořad se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(podcastShowProvider(showId)),
        ),
        data: (show) {
          final theme = Theme.of(context);
          final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(podcastShowProvider(showId)),
            child: ListView(
              padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
              children: [
                Center(child: _Art(url: show.artworkUrl, size: 200)),
                const SizedBox(height: AppSpacing.md),
                Text(show.title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                if (show.author != null) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(show.author!, style: muted, textAlign: TextAlign.center),
                ],
                const SizedBox(height: AppSpacing.md),
                Center(
                  child: GlassButton(
                    label: show.subscribed ? 'Odebíráš' : 'Odebírat',
                    icon: show.subscribed ? Symbols.check_rounded : Symbols.add_rounded,
                    style: show.subscribed ? GlassButtonStyle.tonal : GlassButtonStyle.prominent,
                    onPressed: () async {
                      try {
                        await setPodcastSubscribed(ref, show.id, !show.subscribed);
                      } catch (_) {
                        if (context.mounted) toast(context, 'Nepodařilo se změnit odběr');
                      }
                    },
                  ),
                ),
                if (show.description != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(show.description!, style: muted, maxLines: 4, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: AppSpacing.md),
                Text('Epizody', style: theme.textTheme.titleMedium),
                if (show.episodes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Text('Žádné epizody k přehrání.', style: muted),
                  ),
                for (final e in show.episodes) PodcastEpisodeTile(episode: e, showId: show.id),
              ],
            ),
          );
        },
      ),
    );
  }
}
