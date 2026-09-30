import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/year_in_review_model.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/surface_card.dart';
import '../../widgets/media_card.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/queue_action_bar.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';

final yearInReviewProvider = FutureProvider.autoDispose<YearInReviewModel>((ref) {
  return ref.watch(recommendationsRepositoryProvider).yearInReview(limit: 10);
});

/// "Rok v hudbě" -- souhrn top skladeb/interpretů + počtu poslechů za
/// poslední rok z ListenBrainz statistik (`GET /recommendations/year-in-review`,
/// viz backend `RecommendationService.year_in_review`). Prázdný stav (účet
/// zatím nemá dost poslechů na spočtenou statistiku) je legitimní, ne chyba
/// -- stejná filosofie jako zbytek `RecommendationService`.
class YearInReviewScreen extends ConsumerWidget {
  const YearInReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final review = ref.watch(yearInReviewProvider);

    return Scaffold(
      bottomNavigationBar: const PlayerBar(),
      appBar: const SectionAppBar('Rok v hudbě'),
      body: review.when(
        data: (data) => data.isEmpty
            ? const EmptyState(
                icon: Symbols.equalizer_rounded,
                message: 'Zatím nemáme dost poslechové historie na roční souhrn – '
                    'ListenBrainz statistiku spočítá, jakmile budeš mít víc poslechů.',
              )
            : _YearInReviewBody(data: data),
        loading: () => const LoadingState(),
        error: (error, stack) => ErrorState(
          message: 'Souhrn se nepodařilo načíst.',
          error: error,
          onRetry: () => ref.invalidate(yearInReviewProvider),
        ),
      ),
    );
  }
}

class _YearInReviewBody extends StatelessWidget {
  const _YearInReviewBody({required this.data});
  final YearInReviewModel data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: SurfaceCard(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Symbols.equalizer_rounded, size: 32),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${data.totalListens}', style: theme.textTheme.headlineMedium),
                  Text('poslechů za poslední rok', style: theme.textTheme.bodyMedium),
                ],
              ),
            ],
          ),
        ),
        ),
        if (data.topArtists.isNotEmpty) ...[
          const SectionHeader('Nejposlouchanější interpreti'),
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              itemCount: data.topArtists.length,
              itemBuilder: (context, i) {
                final a = data.topArtists[i];
                return Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: SizedBox(
                    width: 130,
                    child: MediaCard(
                      shape: MediaCardShape.circle,
                      placeholderIcon: Symbols.person_rounded,
                      title: '${i + 1}. ${a.name}',
                      imageUrl: a.coverImageUrl,
                      artworkKey: (releaseId: null, artistId: a.id),
                      onTap: () => context.push('/artists/${a.id}'),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (data.topTracks.isNotEmpty) ...[
          const SectionHeader('Nejposlouchanější skladby'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            child: QueueActionBar(tracks: data.topTracks, sourceLabel: 'Rok v hudbě'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Column(
              children: [
                for (var i = 0; i < data.topTracks.length; i++)
                  TrackTile(
                    recording: data.topTracks[i],
                    leadingIndex: i + 1,
                    queueRecordings: data.topTracks,
                    sourceLabel: 'Rok v hudbě',
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
