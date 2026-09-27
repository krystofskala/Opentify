import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/availability.dart';
import '../../models/playlist_model.dart';
import '../../models/recording_model.dart';
import '../../state/artwork_provider.dart';
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../state/provisioning_controller.dart';

final discoverProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).discover();
});

final dailyJamsProvider = FutureProvider.autoDispose<PlaylistDetailModel>((ref) {
  return ref.watch(recommendationsRepositoryProvider).dailyJams();
});

/// Nejposlouchanější nahrávky nastaveného účtu přímo z jeho ListenBrainz
/// statistik -- na rozdíl od Daily Jams/Objevuj (čekají na dávkově počítané
/// doporučení) stačí, aby účet měl vůbec nějaké zaznamenané poslechy.
final myTopTracksProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).myTopTracks();
});

/// Sitewide žebříček veřejné komunity ListenBrainz -- ne dat téhle instance,
/// viz `RecommendationsRepository.trending`.
final trendingProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).trending();
});

/// Top nahrávky uživatelů s podobným vkusem na veřejném ListenBrainz --
/// prázdné, dokud LISTENBRAINZ_USERNAME není skutečný účet s historií.
final communityPicksProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).communityPicks();
});

/// Domovská obrazovka, tři vrstvy podle zdroje dat:
///   - osobní ("Pro tebe"/"Moje"): `Daily Jams` (přednostně z Liked Songs
///     naimportovaných v Profilu, jinak z ListenBrainz troi patche) a
///     `Moje nejposlouchanější` (přímo statistiky nastaveného účtu).
///   - `Objevuj`: širší doporučení pro nastavený účet z ListenBrainz.
///   - globální (odděleně, viz zadání): `Populární na serveru` (sitewide
///     žebříček celé veřejné komunity ListenBrainz) a `Komunitní objevy`
///     (top nahrávky posluchačů s podobným vkusem).
/// Server sám žádné poslechy nesleduje (docs/ARCHITECTURE.md, otevřená
/// otázka #3 single- vs multi-user) -- "komunita" tu vždy znamená
/// ListenBrainz komunitu, ne uživatele téhle instance. Backend vrací
/// prázdný výsledek, dokud podkladová data nejsou k dispozici -- to je tady
/// legitimní prázdný stav, ne chyba.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dailyJams = ref.watch(dailyJamsProvider);
    final discover = ref.watch(discoverProvider);
    final myTop = ref.watch(myTopTracksProvider);
    final trending = ref.watch(trendingProvider);
    final community = ref.watch(communityPicksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Opentify')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dailyJamsProvider);
          ref.invalidate(discoverProvider);
          ref.invalidate(myTopTracksProvider);
          ref.invalidate(trendingProvider);
          ref.invalidate(communityPicksProvider);
        },
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const _SectionHeader(
              'Daily Jams',
              badge: _SectionBadge(icon: Icons.favorite, label: 'Pro tebe', color: Colors.pinkAccent),
            ),
            dailyJams.when(
              data: (playlist) => playlist.items.isEmpty
                  ? const _EmptyState(
                      message: 'Zatím žádný denní mix -- naimportuj Liked Songs v Profilu, '
                          'nebo počkej, až ListenBrainz nasbírá poslechovou historii.',
                    )
                  : _TrackCardRow(recordings: playlist.items),
              loading: () => const _LoadingRow(),
              error: (error, stack) => _ErrorRow(error: error),
            ),
            const SizedBox(height: 8),
            const _SectionHeader(
              'Moje nejposlouchanější',
              badge: _SectionBadge(icon: Icons.person, label: 'Moje', color: Colors.purpleAccent),
            ),
            myTop.when(
              data: (recordings) => recordings.isEmpty
                  ? const _EmptyState(
                      message: 'ListenBrainz účet zatím nemá dost zaznamenaných poslechů pro statistiku.',
                    )
                  : _TrackCardRow(recordings: recordings),
              loading: () => const _LoadingRow(),
              error: (error, stack) => _ErrorRow(error: error),
            ),
            const SizedBox(height: 8),
            const _SectionHeader('Objevuj'),
            discover.when(
              data: (recordings) => recordings.isEmpty
                  ? const _EmptyState(message: 'Zatím nic k objevování -- zkus to za pár dní znovu.')
                  : _TrackCardRow(recordings: recordings),
              loading: () => const _LoadingRow(),
              error: (error, stack) => _ErrorRow(error: error),
            ),
            const SizedBox(height: 8),
            const _SectionHeader(
              'Populární na serveru',
              badge: _SectionBadge(icon: Icons.local_fire_department, label: 'Trending', color: Colors.deepOrange),
            ),
            trending.when(
              data: (recordings) => recordings.isEmpty
                  ? const _EmptyState(message: 'Veřejný ListenBrainz teď žebříček nevrací -- zkus to později.')
                  : _TrackCardRow(recordings: recordings),
              loading: () => const _LoadingRow(),
              error: (error, stack) => _ErrorRow(error: error),
            ),
            const SizedBox(height: 8),
            const _SectionHeader(
              'Komunitní objevy',
              badge: _SectionBadge(icon: Icons.groups, label: 'Community', color: Colors.teal),
            ),
            community.when(
              data: (recordings) => recordings.isEmpty
                  ? const _EmptyState(
                      message: 'Zatím nic -- nastav LISTENBRAINZ_USERNAME na účet s poslechovou historií.',
                    )
                  : _TrackCardRow(recordings: recordings),
              loading: () => const _LoadingRow(),
              error: (error, stack) => _ErrorRow(error: error),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.badge});
  final String title;
  final Widget? badge;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            if (badge != null) ...[const SizedBox(width: 8), badge!],
          ],
        ),
      );
}

/// Skleněný štítek u názvu sekce -- vizuálně odlišuje "Populární na
/// serveru"/"Komunitní objevy" (data z veřejného ListenBrainz) od osobních
/// Daily Jams/Objevuj (z lokálně nastaveného účtu).
class _SectionBadge extends StatelessWidget {
  const _SectionBadge({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      );
}

class _TrackCardRow extends StatelessWidget {
  const _TrackCardRow({required this.recordings});
  final List<RecordingModel> recordings;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 198,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: recordings.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _TrackCard(recording: recordings[index]),
          ),
        ),
      );
}

/// Karta jedné doporučené skladby -- `Recording` ve schématu nenese obal
/// (viz docs/openapi.yaml), takže se zkusí dohledat přes
/// `recordingArtworkProvider` (album, jinak fotka interpreta); teprve když
/// ani jedno není k dispozici, zůstane přechodový gradient s notovou ikonou.
class _TrackCard extends ConsumerWidget {
  const _TrackCard({required this.recording});
  final RecordingModel recording;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final provisioning = ref.watch(provisioningControllerProvider);
    final trackState = provisioning[recording.id];
    final isAvailable = trackState?.status == 'AVAILABLE' || recording.availability == Availability.available;
    final isInFlight = trackState?.isInFlight ?? false;
    final artworkUrl = recording.releaseId != null || recording.artistId != null
        ? ref.watch(recordingArtworkProvider((releaseId: recording.releaseId, artistId: recording.artistId))).valueOrNull
        : null;

    void onTap() {
      if (isAvailable) {
        final streamUrl = ref.read(provisioningRepositoryProvider).streamUrl(recording.id);
        ref.read(audioPlayerControllerProvider.notifier).playTrack(
              NowPlayingInfo(recordingId: recording.id, title: recording.title, artworkUrl: artworkUrl),
              streamUrl,
            );
      } else if (!isInFlight) {
        ref.read(provisioningControllerProvider.notifier).provision(recording.id);
      }
    }

    return SizedBox(
      width: 140,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: artworkUrl != null
                          ? CachedNetworkImage(
                              imageUrl: artworkUrl,
                              fit: BoxFit.cover,
                              fadeInDuration: const Duration(milliseconds: 250),
                              placeholder: (context, url) => _GradientPlaceholder(theme: theme),
                              errorWidget: (context, url, error) => _GradientPlaceholder(theme: theme),
                            )
                          : _GradientPlaceholder(theme: theme),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: isInFlight
                          ? const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              isAvailable ? Icons.play_circle_fill : Icons.download_outlined,
                              color: Colors.white,
                              shadows: const [Shadow(blurRadius: 6)],
                            ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(recording.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    Text(_subtitleFor(recording), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Trending/Community karty mají `listenCount` místo `durationMs` (ListenBrainz
/// stats žádnou délku nenesou) -- zobrazí se, co je k dispozici.
String _subtitleFor(RecordingModel recording) {
  final count = recording.listenCount;
  if (count == null) return recording.durationLabel;
  final formatted = count.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (match) => ' ',
      );
  return '$formatted poslechů';
}

class _GradientPlaceholder extends StatelessWidget {
  const _GradientPlaceholder({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [theme.colorScheme.primaryContainer, theme.colorScheme.tertiaryContainer],
          ),
        ),
        child: const Center(child: Icon(Icons.music_note, size: 36)),
      );
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.error});
  final Object error;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Nepodařilo se načíst: $error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
      );
}
