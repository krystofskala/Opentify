import '../../routing/branches.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/cz_plural.dart';
import '../../data/listen_later_repository.dart';
import '../../models/recording_model.dart';
import '../../state/listen_later_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';
import 'pinned_tile.dart';

const _title = 'Shazam';

/// Všechno, co uživatel kdy poznal přes Open Shazam (v appce, později
/// i z widgetu / Ovládacího centra v iOS) -- nejnovější nahoře. Položky se
/// dál ukládají do "Poslechnout později" (`source = shazam`); tady zůstávají
/// i po poslechnutí.
List<LaterItem> shazamItems(LaterList data) => [
      for (final i in [...data.active, ...data.listened])
        if (i.fromShazam && i.kind == LaterKind.track && i.track != null) i,
    ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

/// Dlaždice v Knihovně › Playlisty.
class ShazamCard extends ConsumerWidget {
  const ShazamCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final data = ref.watch(listenLaterProvider).valueOrNull;
    final count = data == null ? null : shazamItems(data).length;
    return PinnedTile(
      icon: Symbols.graphic_eq_rounded,
      iconFill: false,
      title: _title,
      subtitle: count == null || count == 0 ? 'Poznané skladby' : songsCount(count),
      colors: [scheme.secondaryContainer, scheme.tertiaryContainer],
      iconBackground: scheme.secondary,
      iconColor: scheme.onSecondary,
      textColor: scheme.onSecondaryContainer,
      onTap: () => context.push('/library/shazam'),
    );
  }
}

class ShazamCollectionScreen extends ConsumerWidget {
  const ShazamCollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(listenLaterProvider);
    return Scaffold(
      appBar: SectionAppBar(
        _title,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: GlassButton(
              label: 'Poznat skladbu',
              icon: Symbols.graphic_eq_rounded,
              style: GlassButtonStyle.tonal,
              compact: true,
              onPressed: () => context.push('/shazam'),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const ShellBarSpace(),
      body: list.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Seznam se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(listenLaterProvider),
        ),
        data: (data) {
          final items = shazamItems(data);
          if (items.isEmpty) {
            return const EmptyState(
              icon: Symbols.graphic_eq_rounded,
              message: 'Zatím nic. Co poznáš přes „Poznat skladbu“, se uloží sem '
                  '(a do „Na později“).',
            );
          }
          final tracks = <RecordingModel>[for (final i in items) i.track!];
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.xl + MediaQuery.paddingOf(context).bottom),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              final when = item.addedAt.toLocal();
              final date = '${when.day}. ${when.month}. ${when.year}';
              return TrackTile(
                recording: item.track!,
                queueRecordings: tracks,
                sourceLabel: _title,
                subtitle: [if (item.track!.artistName case final a?) a, date].join(' · '),
              );
            },
          );
        },
      ),
    );
  }
}
