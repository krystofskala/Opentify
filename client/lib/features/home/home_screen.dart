import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist_model.dart';
import '../../models/recording_model.dart';
import '../../state/providers.dart';
import '../../widgets/recording_tile.dart';

final discoverProvider = FutureProvider.autoDispose<List<RecordingModel>>((ref) {
  return ref.watch(recommendationsRepositoryProvider).discover();
});

final dailyJamsProvider = FutureProvider.autoDispose<PlaylistDetailModel>((ref) {
  return ref.watch(recommendationsRepositoryProvider).dailyJams();
});

/// Domovská obrazovka: `Daily Jams` + `Discover`, oba z Recommendation
/// Service (GET /recommendations/*). Backend vrací prázdný výsledek, dokud
/// ListenBrainz nemá pro uživatele dost poslechové historie -- to je tady
/// legitimní prázdný stav, ne chyba.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dailyJams = ref.watch(dailyJamsProvider);
    final discover = ref.watch(discoverProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Opentify')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dailyJamsProvider);
          ref.invalidate(discoverProvider);
        },
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _SectionHeader('Daily Jams'),
            dailyJams.when(
              data: (playlist) => playlist.items.isEmpty
                  ? const _EmptyState(
                      message: 'Zatím žádný denní mix -- ListenBrainz potřebuje víc poslechové historie.',
                    )
                  : _RecordingList(recordings: playlist.items),
              loading: () => const _LoadingRow(),
              error: (error, stack) => _ErrorRow(error: error),
            ),
            const Divider(height: 32),
            _SectionHeader('Objevuj'),
            discover.when(
              data: (recordings) => recordings.isEmpty
                  ? const _EmptyState(message: 'Zatím nic k objevování -- zkus to za pár dní znovu.')
                  : _RecordingList(recordings: recordings),
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
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      );
}

class _RecordingList extends StatelessWidget {
  const _RecordingList({required this.recordings});
  final List<RecordingModel> recordings;

  @override
  Widget build(BuildContext context) => Column(
        children: [for (final r in recordings) RecordingTile(recording: r)],
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
