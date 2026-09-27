import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist_model.dart';
import '../../state/providers.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/recording_tile.dart';
import '../home/home_screen.dart' show dailyJamsProvider;

final likedSongsProvider = FutureProvider.autoDispose<PlaylistDetailModel>((ref) {
  return ref.watch(libraryRepositoryProvider).likedSongs();
});

/// Osobní profil: import Spotify "Liked Songs" exportu a sken lokální hudební
/// knihovny (`MUSIC_DIR`, viz docker-compose.yml) -- obojí naplňuje stejnou
/// lokální knihovnu, na které teď primárně staví "Daily Jams" na Home
/// (viz `RecommendationService.daily_jams`).
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final likedSongs = ref.watch(likedSongsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      bottomNavigationBar: const PlayerBar(),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(likedSongsProvider),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ActionCard(
              icon: Icons.cloud_upload_outlined,
              title: 'Import ze Spotify',
              description:
                  'Nahraj YourLibrary.json ze svého Spotify exportu (Nastavení účtu → '
                  'Soukromí → Stáhnout svá data). Naimportované skladby se objeví níž '
                  'jako Liked Songs a použijí se pro tvůj denní mix.',
              buttonLabel: 'Vybrat soubor…',
              onPressed: () => _importFromSpotify(context, ref),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Icons.folder_outlined,
              title: 'Lokální knihovna',
              description:
                  'Projde hudební soubory namapované z hostitele (proměnná MUSIC_DIR '
                  'v .env) a zaeviduje je jako rovnou dostupné, bez obstarávání.',
              buttonLabel: 'Skenovat knihovnu',
              onPressed: () => _scanLibrary(context, ref),
            ),
            const SizedBox(height: 20),
            Text('Liked Songs', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            likedSongs.when(
              data: (playlist) => playlist.items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Zatím nic -- naimportuj Liked Songs ze Spotify výše.'),
                    )
                  : Column(children: [for (final r in playlist.items) RecordingTile(recording: r)]),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stack) => Text('Nepodařilo se načíst: $error'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromSpotify(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return; // uživatel zavřel dialog
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) return; // web s withData:true je vždy dodá, jiné platformy teoreticky ne

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Importuji…')));
    try {
      final result = await ref.read(libraryRepositoryProvider).importSpotifyLibrary(bytes, file.name);
      ref.invalidate(likedSongsProvider);
      ref.invalidate(dailyJamsProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Hotovo: ${result.matched}/${result.totalInFile} napárováno '
            '(${result.alreadyLiked} už bylo v Liked Songs, ${result.skipped} přeskočeno).',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import selhal: $e')));
    }
  }

  Future<void> _scanLibrary(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Skenuji knihovnu…')));
    try {
      final result = await ref.read(libraryRepositoryProvider).scan();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Nalezeno ${result.scanned} souborů v ${result.root}, '
            '${result.matched} zaevidováno, ${result.skippedNoTags} bez tagů, ${result.errors} chyb.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Sken selhal: $e')));
    }
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassContainer(
      borderRadius: BorderRadius.circular(18),
      tint: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 10),
              Text(title, style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
          ),
        ],
      ),
    );
  }
}
