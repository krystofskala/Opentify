import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/media_card.dart' show ArtworkImage;
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../profile/history_screen.dart' show historyDayLabel;
import 'spoken_data.dart';

/// Položka historie mluveného slova: kniha nebo epizoda a kolik se jí ten
/// den poslouchalo (backend `GET /spoken/history`, `app/spoken/history.py`).
typedef SpokenHistoryItem = ({String kind, String ref, String title, String? subtitle, String? coverUrl, String? showId, int seconds, bool gone});
typedef SpokenHistoryDay = ({DateTime day, List<SpokenHistoryItem> items});

final spokenHistoryProvider = FutureProvider.autoDispose<List<SpokenHistoryDay>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/spoken/history');
  return [
    for (final d in (json['days'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
      (
        day: DateTime.parse(d['day'] as String),
        items: [
          for (final i in (d['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
            (
              kind: i['kind'] as String? ?? 'book',
              ref: i['ref'] as String? ?? '',
              title: i['title'] as String? ?? '',
              subtitle: i['subtitle'] as String?,
              coverUrl: spokenCoverUrl(i['coverUrl'] as String?),
              showId: i['showId'] as String?,
              seconds: (i['seconds'] as num?)?.toInt() ?? 0,
              gone: i['gone'] as bool? ?? false,
            ),
        ],
      ),
  ];
});

String _duration(int seconds) {
  final m = (seconds / 60).round();
  if (m < 1) return 'méně než minuta';
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

/// Profil › Historie v režimu mluveného slova -- co sis kdy poslouchal a jak
/// dlouho, po dnech (nejnovější nahoře). Jen vlastní profil.
class SpokenHistoryScreen extends ConsumerWidget {
  const SpokenHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spokenHistoryProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: const SectionAppBar('Historie'),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Historii se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(spokenHistoryProvider),
        ),
        data: (days) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(spokenHistoryProvider),
          child: days.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 80),
                  EmptyState(
                    icon: Symbols.history_rounded,
                    message: 'Zatím tu nic není – knihy a epizody se sem zapisují od 8. 10. 2026, jak je posloucháš.',
                  ),
                ])
              : ListView(
                  padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
                  children: [
                    for (final (i, d) in days.indexed) ...[
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpacing.md, bottom: AppSpacing.xs),
                        child: Row(
                          children: [
                            Expanded(child: Text(historyDayLabel(d.day, DateTime.now()), style: theme.textTheme.titleMedium)),
                            Text(_duration(d.items.fold(0, (a, b) => a + b.seconds)), style: muted),
                          ],
                        ),
                      ),
                      for (final it in d.items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: SizedBox.square(
                            dimension: 48,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadii.xs),
                              child: ArtworkImage(
                                url: it.coverUrl,
                                icon: it.kind == 'book' ? Symbols.menu_book_rounded : Symbols.podcasts_rounded,
                              ),
                            ),
                          ),
                          title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [if (it.subtitle != null) it.subtitle!, _duration(it.seconds)].join(' · '),
                            style: muted,
                          ),
                          onTap: it.gone
                              ? null
                              : () => context.push(it.kind == 'book'
                                  ? '/spoken/book/${it.ref}'
                                  : (it.showId != null ? '/podcasts/show/${it.showId}' : '/spoken')),
                        ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
