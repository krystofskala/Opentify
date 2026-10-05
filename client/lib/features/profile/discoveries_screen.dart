import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/recording_model.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surface_card.dart';
import '../../widgets/track_tile.dart';

/// Profil › Objevy -- kolik nových skladeb tě chytlo a odkud přišly
/// (backend app/home/discoveries.py). Chytla = do 30 dní sis ji pustil ještě
/// aspoň ve 2 dalších dnech, nebo sis ji uložil.
class DiscoverySource {
  const DiscoverySource(this.name, this.newCount, this.caught, this.pending);
  final String name;
  final int newCount;
  final int caught;
  final int pending;
}

class DiscoveriesData {
  const DiscoveriesData({required this.total, required this.sources, required this.recent, required this.days});
  final DiscoverySource total;
  final List<DiscoverySource> sources;
  final List<RecordingModel> recent;
  final int days;
}

final discoveriesProvider = FutureProvider.autoDispose<DiscoveriesData>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/home/discoveries');
  DiscoverySource source(Map<String, dynamic> m, [String? name]) => DiscoverySource(
        name ?? m['source'] as String,
        m['new'] as int? ?? 0,
        m['caught'] as int? ?? 0,
        m['pending'] as int? ?? 0,
      );
  return DiscoveriesData(
    total: source(json['total'] as Map<String, dynamic>, 'Celkem'),
    sources: [for (final s in json['sources'] as List<dynamic>) source(s as Map<String, dynamic>)],
    recent: [
      for (final t in json['recentCaught'] as List<dynamic>? ?? const [])
        RecordingModel.fromJson(t as Map<String, dynamic>),
    ],
    days: json['days'] as int? ?? 180,
  );
});

class DiscoveriesScreen extends ConsumerWidget {
  const DiscoveriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(discoveriesProvider);
    return Scaffold(
      appBar: const SectionAppBar('Objevy'),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Objevy se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(discoveriesProvider),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(discoveriesProvider),
          child: _Body(data: data),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});
  final DiscoveriesData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final total = data.total;
    if (total.newCount == 0) {
      return ListView(children: const [
        SizedBox(height: 80),
        EmptyState(message: 'Zatím tu nic není – objevy se objeví, až začneš poslouchat nové věci.'),
      ]);
    }
    final months = (data.days / 30).round();
    return ListView(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
      children: [
        Text(
          'Nové skladby za posledních $months měsíců. Chytla tě ta, kterou sis do 30 dní pustil ještě '
          'aspoň ve 2 dalších dnech, nebo sis ji uložil.',
          style: muted,
        ),
        const SizedBox(height: AppSpacing.md),
        SurfaceCard(
          child: Row(
            children: [
              _Number(value: total.newCount, label: 'nových'),
              _Number(value: total.caught, label: 'tě chytlo', strong: true),
              _Number(value: total.pending, label: 'se ještě uvidí'),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Odkud přišly', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        for (final s in data.sources) _SourceRow(source: s),
        if (data.recent.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('Naposledy tě chytly', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          for (final r in data.recent) TrackTile(recording: r, queueRecordings: data.recent, sourceLabel: 'Objevy'),
        ],
      ],
    );
  }
}

class _Number extends StatelessWidget {
  const _Number({required this.value, required this.label, this.strong = false});
  final int value;
  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: strong ? theme.colorScheme.primary : null,
            ),
          ),
          Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source});
  final DiscoverySource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decided = source.newCount - source.pending;
    final share = decided > 0 ? source.caught / decided : 0.0;
    final detail = [
      '${source.caught} z ${source.newCount} chytlo',
      if (source.pending > 0) '${source.pending} se ještě uvidí',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(_iconFor(source.name), size: 22, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.name, style: theme.textTheme.bodyLarge),
                Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.xxs),
                  child: LinearProgressIndicator(value: share, minHeight: 4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String name) => switch (name) {
        'Pusť teď' => Symbols.play_circle_rounded,
        'Denní mixy' || 'Tvoje mixy' => Symbols.auto_awesome_rounded,
        'Objevy týdne' => Symbols.explore_rounded,
        'Rádio' => Symbols.radio_rounded,
        'Alba' => Symbols.album_rounded,
        'Stránky interpretů' => Symbols.person_rounded,
        'Hledání' => Symbols.search_rounded,
        'Shazam' => Symbols.graphic_eq_rounded,
        'Tvoje playlisty' || 'Playlisty' => Symbols.queue_music_rounded,
        'Žánry a žebříčky' => Symbols.category_rounded,
        'Knihovna' => Symbols.library_music_rounded,
        _ when name.contains('import') => Symbols.cloud_download_rounded,
        _ => Symbols.home_rounded,
      };
}
