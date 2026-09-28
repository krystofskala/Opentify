import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/library_repository.dart';
import '../../models/playlist_model.dart';
import '../../models/recording_model.dart';
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/recently_played_pill.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_list_sheet.dart';
import '../../widgets/track_tile.dart';
import '../../routing/home_shell.dart' show navBottomInset;

final genresProvider = FutureProvider.autoDispose<List<LocalGenre>>((ref) {
  return ref.watch(libraryRepositoryProvider).genres();
});

final czechMusicProvider = FutureProvider.autoDispose<LocalTracksPage>((ref) {
  return ref.watch(libraryRepositoryProvider).czechMusic();
});

final discoverProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).discover();
});

final dailyJamsProvider = FutureProvider.autoDispose<PlaylistDetailModel>((ref) {
  return ref.watch(recommendationsRepositoryProvider).dailyJams();
});

/// Nejposlouchanější nahrávky nastaveného účtu přímo z jeho ListenBrainz
/// statistik.
final myTopTracksProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).myTopTracks();
});

/// Sitewide žebříček veřejné komunity ListenBrainz.
final trendingProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).trending();
});

/// Top nahrávky uživatelů s podobným vkusem na veřejném ListenBrainz.
final communityPicksProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).communityPicks();
});

/// Domovská obrazovka -- osobní (Daily Jams, Moje nejposlouchanější),
/// Objevuj, globální (Trendy, Komunita, ListenBrainz), žánry a česká hudba.
/// Prázdné sekce jsou legitimní stav (data ještě nejsou), ne chyba.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentlyPlayed = ref.watch(audioPlayerControllerProvider.select((s) => s.recentlyPlayed));
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SectionAppBar('Opentify'),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dailyJamsProvider);
          ref.invalidate(discoverProvider);
          ref.invalidate(myTopTracksProvider);
          ref.invalidate(trendingProvider);
          ref.invalidate(communityPicksProvider);
          ref.invalidate(genresProvider);
          ref.invalidate(czechMusicProvider);
        },
        child: ListView(
          padding: EdgeInsets.only(bottom: AppSpacing.lg + navBottomInset(context)),
          children: [
            // PixelPlayerova "bublinová" řada naposledy přehraných -- skrytá,
            // dokud toho není aspoň pár.
            if (recentlyPlayed.length >= 3) ...[
              const SectionHeader('Naposledy přehráno'),
              SizedBox(
                height: 66,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  itemCount: recentlyPlayed.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: RecentlyPlayedPill(info: recentlyPlayed[index], queue: recentlyPlayed),
                  ),
                ),
              ),
            ],
            _TrackRailSection(
              title: 'Daily Jams',
              badge: SectionBadge(icon: Symbols.favorite_rounded, label: 'Pro tebe', color: scheme.primary),
              value: ref.watch(dailyJamsProvider).whenData((p) => p.items),
              onRetry: () => ref.invalidate(dailyJamsProvider),
              emptyMessage: 'Zatím žádný denní mix -- naimportuj Liked Songs v Profilu, '
                  'nebo počkej, až ListenBrainz nasbírá poslechovou historii.',
            ),
            _TrackRailSection(
              title: 'Moje nejposlouchanější',
              badge: SectionBadge(icon: Symbols.person_rounded, label: 'Moje', color: scheme.secondary),
              value: ref.watch(myTopTracksProvider),
              onRetry: () => ref.invalidate(myTopTracksProvider),
              emptyMessage: 'ListenBrainz účet zatím nemá dost zaznamenaných poslechů pro statistiku.',
            ),
            _TrackRailSection(
              title: 'Objevuj',
              value: ref.watch(discoverProvider),
              onRetry: () => ref.invalidate(discoverProvider),
              emptyMessage: 'Zatím nic k objevování -- zkus to za pár dní znovu.',
            ),
            _TrackRailSection(
              title: 'Populární na serveru',
              badge: SectionBadge(icon: Symbols.local_fire_department_rounded, label: 'Trendy', color: scheme.tertiary),
              value: ref.watch(trendingProvider),
              onRetry: () => ref.invalidate(trendingProvider),
              emptyMessage: 'Veřejný ListenBrainz teď žebříček nevrací -- zkus to později.',
            ),
            _TrackRailSection(
              title: 'Komunitní objevy',
              badge: SectionBadge(icon: Symbols.groups_rounded, label: 'Komunita', color: scheme.secondary),
              value: ref.watch(communityPicksProvider),
              onRetry: () => ref.invalidate(communityPicksProvider),
              emptyMessage: 'Zatím nic -- nastav LISTENBRAINZ_USERNAME na účet s poslechovou historií.',
            ),
            const SectionHeader('Podle nálady a žánru'),
            ref.watch(genresProvider).when(
                  data: (items) => items.isEmpty
                      ? const EmptyState(
                          compact: true,
                          message: 'Zatím žádné rozpoznané žánry -- otevři pár alb v knihovně, ať se dotáhnou.',
                        )
                      : _GenreChipRow(genres: items),
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                    child: Row(
                      children: [
                        SkeletonBox(width: 90, height: 32, radius: AppRadii.pill),
                        SizedBox(width: AppSpacing.xs),
                        SkeletonBox(width: 110, height: 32, radius: AppRadii.pill),
                        SizedBox(width: AppSpacing.xs),
                        SkeletonBox(width: 80, height: 32, radius: AppRadii.pill),
                      ],
                    ),
                  ),
                  error: (error, stack) => ErrorState(
                    compact: true,
                    message: 'Žánry se nepodařilo načíst.',
                    onRetry: () => ref.invalidate(genresProvider),
                  ),
                ),
            _TrackRailSection(
              title: 'Česká hudba',
              value: ref.watch(czechMusicProvider).whenData((p) => p.items),
              onRetry: () => ref.invalidate(czechMusicProvider),
              emptyMessage: 'Zatím žádní čeští interpreti rozpoznaní v knihovně.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Jedna sekce Home -- nadpis (+ štítek, "Zobrazit vše"), pak skeleton,
/// prázdný stav, chyba nebo vodorovná řada karet. Dřív měla každá sekce
/// vlastní kopii téhož `.when(...)` bloku.
class _TrackRailSection extends StatelessWidget {
  const _TrackRailSection({
    required this.title,
    required this.value,
    required this.onRetry,
    required this.emptyMessage,
    this.badge,
  });

  final String title;
  final Widget? badge;
  final AsyncValue<List<RecordingModel>> value;
  final VoidCallback onRetry;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final items = value.valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title,
          badge: badge,
          onSeeAll: items != null && items.length > 3
              ? () => showTrackListSheet(context, title: title, recordings: items)
              : null,
        ),
        value.when(
          data: (recordings) => recordings.isEmpty
              ? EmptyState(compact: true, message: emptyMessage)
              : _TrackCardRow(recordings: recordings, sourceLabel: title),
          loading: () => const SkeletonCardRail(),
          error: (error, stack) => ErrorState(compact: true, message: 'Sekci se nepodařilo načíst.', onRetry: onRetry),
        ),
      ],
    );
  }
}

/// Vodorovná řada žánrových čipů -- klik otevře sheet se skladbami žánru.
class _GenreChipRow extends ConsumerWidget {
  const _GenreChipRow({required this.genres});
  final List<LocalGenre> genres;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        height: 40,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          itemCount: genres.length,
          itemBuilder: (context, index) {
            final genre = genres[index];
            return Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: ActionChip(
                label: Text('${genre.genre} · ${genre.trackCount}'),
                onPressed: () => showTrackListSheet(
                  context,
                  title: genre.genre,
                  load: (ref) async => (await ref.read(libraryRepositoryProvider).tracksByGenre(genre.genre)).items,
                ),
              ),
            );
          },
        ),
      );
}

/// Karty skladeb v jedné vodorovně scrollovatelné sekci -- `sourceLabel`
/// (název sekce) se propíše do "Přehráváno z …" v přehrávači.
class _TrackCardRow extends StatelessWidget {
  const _TrackCardRow({required this.recordings, required this.sourceLabel});
  final List<RecordingModel> recordings;
  final String sourceLabel;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 198,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          itemCount: recordings.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: SizedBox(
              width: 140,
              child: TrackTile(
                layout: TrackTileLayout.card,
                recording: recordings[index],
                subtitle: _subtitleFor(recordings[index]),
                queueRecordings: recordings,
                sourceLabel: sourceLabel,
                animationIndex: index,
              ),
            ),
          ),
        ),
      );
}

/// Karta ukazuje interpreta (proklikávací); jen Trendy/Komunita, kde
/// interpret chybí, spadnou na počet poslechů z ListenBrainz.
String? _subtitleFor(RecordingModel recording) {
  if (recording.artistName != null) return null;
  final count = recording.listenCount;
  if (count == null) return null;
  final formatted = count.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (match) => ' ');
  return '$formatted poslechů';
}
