import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/recording_model.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/app_mode.dart';
import '../../state/providers.dart';
import '../spoken/spoken_history_screen.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_tile.dart';

/// Profil › Historie -- posledních 100 poslechů v appce (backend
/// `GET /home/history`), nejnovější nahoře, po dnech. Klepnutí pustí jen
/// tu skladbu (jako v hledání), zbytek přes běžné menu skladby.
typedef HistoryEntry = ({RecordingModel recording, DateTime playedAt, String? playedFrom});

final historyProvider = FutureProvider.autoDispose<List<HistoryEntry>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/home/history', query: {'limit': '100'});
  return [
    for (final item in json['items'] as List<dynamic>? ?? const [])
      (
        recording: RecordingModel.fromJson(item as Map<String, dynamic>),
        playedAt: DateTime.parse(item['playedAt'] as String).toLocal(),
        playedFrom: item['playedFrom'] as String?,
      ),
  ];
});

const _months = [
  'ledna', 'února', 'března', 'dubna', 'května', 'června', //
  'července', 'srpna', 'září', 'října', 'listopadu', 'prosince',
];

/// "Dnes", "Včera", "5. října" (letos), "5. října 2025".
String historyDayLabel(DateTime day, DateTime now) {
  final d = DateTime(day.year, day.month, day.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Dnes';
  if (diff == 1) return 'Včera';
  final base = '${d.day}. ${_months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

String _time(DateTime t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // V režimu mluveného slova historie knih a epizod (po dnech, čas poslechu).
    if (ref.watch(appModeProvider) == AppMode.spoken) return const SpokenHistoryScreen();
    final async = ref.watch(historyProvider);
    return Scaffold(
      appBar: const SectionAppBar('Historie'),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Historii se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(historyProvider),
        ),
        data: (entries) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(historyProvider),
          child: entries.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 80),
                  EmptyState(message: 'Zatím tu nic není – skladba se sem zapíše, když ji poslechneš aspoň do půlky.'),
                ])
              : _HistoryList(entries: entries),
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.entries});
  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final children = <Widget>[];
    String? lastDay;
    for (final e in entries) {
      final day = historyDayLabel(e.playedAt, now);
      if (day != lastDay) {
        lastDay = day;
        children.add(Padding(
          padding: EdgeInsets.only(top: children.isEmpty ? 0 : AppSpacing.md, bottom: AppSpacing.xs),
          child: Text(day, style: theme.textTheme.titleMedium),
        ));
      }
      final r = e.recording;
      children.add(TrackTile(
        recording: r,
        subtitle: [
          if (r.artistName != null) r.artistName!,
          _time(e.playedAt),
          if (e.playedFrom != null && e.playedFrom!.isNotEmpty) e.playedFrom!,
        ].join(' · '),
        // Jako v hledání: hraje jen klepnutá skladba.
        sourceLabel: 'Historie',
      ));
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
      children: children,
    );
  }
}
