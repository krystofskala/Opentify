import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/library_repository.dart';
import '../../models/playlist_model.dart';
import '../../state/liked_songs_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/track_collection.dart';
import '../../widgets/track_tile.dart';
import '../home/home_screen.dart' show dailyJamsProvider;

final likedSongsProvider = FutureProvider.autoDispose<PlaylistDetailModel>((ref) {
  return ref.watch(libraryRepositoryProvider).likedSongs();
});

/// `POST /library/scan` jen odstartuje sken na pozadí (MusicBrainz limituje
/// na 1 request/s, tisíce souborů by se v jednom HTTP requestu nestihly) --
/// tenhle provider čte jeho aktuální stav; `ProfileScreen` ho drží
/// pravidelně obnovovaný, dokud `status == running`.
final scanStatusProvider = FutureProvider.autoDispose<LibraryScanStatus>((ref) {
  return ref.watch(libraryRepositoryProvider).scanStatus();
});

/// Osobní profil: import Spotify "Liked Songs" exportu a sken lokální hudební
/// knihovny (`MUSIC_DIR`, viz docker-compose.yml) -- obojí naplňuje stejnou
/// lokální knihovnu, na které teď primárně staví "Daily Jams" na Home
/// (viz `RecommendationService.daily_jams`).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Timer? _pollTimer;
  final _collection = TrackCollectionController();

  @override
  void dispose() {
    _pollTimer?.cancel();
    _collection.dispose();
    super.dispose();
  }

  /// Zavolat po každém načtení stavu -- pokud sken běží, spustí (nebo nechá
  /// běžet) pravidelné dotazování; jakmile doběhne, časovač sám zruší.
  void _syncPolling(LibraryScanStatus status) {
    if (status.isRunning) {
      _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
        ref.invalidate(scanStatusProvider);
      });
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final likedSongs = ref.watch(likedSongsProvider);
    final likedIds = ref.watch(likedSongsControllerProvider).valueOrNull;
    final scanStatus = ref.watch(scanStatusProvider);
    scanStatus.whenData(_syncPolling);
    // Srdíčko kdekoliv v appce -> seznam tady se hned přizpůsobí: odebrané
    // zmizí okamžitě (filtr podle živé sady), nově přidané po přenačtení.
    ref.listen(likedSongsControllerProvider, (previous, next) {
      if (previous?.valueOrNull?.length != next.valueOrNull?.length) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) ref.invalidate(likedSongsProvider);
        });
      }
    });

    return Scaffold(
      appBar: const SectionAppBar('Profil'),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(likedSongsProvider);
          ref.invalidate(scanStatusProvider);
        },
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
            _ActionCard(
              icon: Symbols.cloud_upload_rounded,
              title: 'Import ze Spotify',
              description:
                  'Nahraj export playlistů (ZIP s CSV, např. z Exportify) nebo '
                  'YourLibrary.json z oficiálního Spotify exportu. Liked Songs se '
                  'použijí pro tvůj denní mix, ostatní playlisty se naimportují '
                  'pod svým jménem.',
              buttonLabel: 'Vybrat soubor…',
              onPressed: () => _importFromSpotify(context),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Symbols.equalizer_rounded,
              title: 'Rok v hudbě',
              description: 'Souhrn nejposlouchanějších skladeb a interpretů za poslední rok.',
              buttonLabel: 'Zobrazit',
              onPressed: () => context.push('/year-in-review'),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Symbols.folder_rounded,
              title: 'Lokální knihovna',
              description:
                  'Projde hudební soubory namapované z hostitele (proměnná MUSIC_DIR '
                  'v .env), spáruje je na MusicBrainz podle tagů (ne podle jména '
                  'souboru/složky) a dotáhne obaly. Běží na pozadí -- MusicBrainz '
                  'dovolí jen 1 dotaz za sekundu, u větší knihovny to chvíli potrvá.',
              buttonLabel: scanStatus.valueOrNull?.isRunning == true ? 'Skenuji…' : 'Skenovat knihovnu',
              onPressed: scanStatus.valueOrNull?.isRunning == true ? null : () => _startScan(context),
            ),
            scanStatus.maybeWhen(
              data: (status) => status.status == 'idle'
                  ? const SizedBox.shrink()
                  : Padding(padding: const EdgeInsets.only(top: 12), child: _ScanStatusCard(status: status)),
              orElse: () => const SizedBox.shrink(),
            ),
                ],
              ),
            ),
            const SectionHeader('Oblíbené skladby'),
            likedSongs.when(
              data: (playlist) {
                final items = likedIds == null
                    ? playlist.items
                    : playlist.items.where((r) => likedIds.contains(r.id)).toList();
                if (items.isEmpty) {
                  return const EmptyState(
                    compact: true,
                    icon: Symbols.favorite_rounded,
                    message: 'Zatím nic -- klepni na srdíčko u skladby, nebo naimportuj Liked Songs ze Spotify výše.',
                  );
                }
                return ListenableBuilder(
                  listenable: _collection,
                  builder: (context, _) {
                    final visible = _collection.apply(items);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TrackCollectionToolbar(
                          controller: _collection,
                          allTracks: items,
                          visibleTracks: visible,
                          sourceLabel: 'Oblíbené skladby',
                        ),
                        if (visible.isEmpty) const EmptyState(compact: true, message: 'Filtru nic neodpovídá.'),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                          child: Column(
                            children: [
                              for (final r in visible)
                                TrackTile(
                                  recording: r,
                                  queueRecordings: visible,
                                  sourceLabel: 'Oblíbené skladby',
                                  selectionMode: _collection.selecting,
                                  selected: _collection.isSelected(r.id),
                                  onSelectedChanged: (value) => _collection.toggle(r.id, value),
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
              loading: () => const SkeletonTrackList(count: 6),
              error: (error, stack) => ErrorState(
                compact: true,
                message: 'Oblíbené skladby se nepodařilo načíst.',
                onRetry: () => ref.invalidate(likedSongsProvider),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromSpotify(BuildContext context) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'zip'],
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
            'Hotovo: ${result.matched}/${result.totalInFile} napárováno napříč '
            '${result.playlistsImported} playlisty (${result.skipped} přeskočeno).',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import selhal: $e')));
    }
  }

  Future<void> _startScan(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(libraryRepositoryProvider).startScan();
      ref.invalidate(scanStatusProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Sken se nepodařilo spustit: $e')));
    }
  }
}

class _ScanStatusCard extends StatelessWidget {
  const _ScanStatusCard({required this.status});
  final LibraryScanStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = status.totalFiles == 0 ? null : status.scanned / status.totalFiles;

    return GlassContainer(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                switch (status.status) {
                  'running' => Symbols.sync_rounded,
                  'done' => Symbols.check_circle_rounded,
                  'error' => Symbols.error_rounded,
                  _ => Symbols.info_rounded,
                },
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                switch (status.status) {
                  'running' => 'Skenuji ${status.root}…',
                  'done' => 'Sken dokončen',
                  'error' => 'Sken selhal',
                  _ => status.status,
                },
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (status.errorMessage != null)
            Text(status.errorMessage!, style: TextStyle(color: theme.colorScheme.error))
          else ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text(
              '${status.scanned}/${status.totalFiles} souborů · '
              '${status.matchedMusicbrainz} přes MusicBrainz · '
              '${status.matchedLocal} jen lokálně · '
              '${status.alreadyScanned} už dřív naskenováno · '
              '${status.skippedNoTags} bez tagů · '
              '${status.errors} chyb',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
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
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassContainer(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      tint: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(AppSpacing.md),
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
