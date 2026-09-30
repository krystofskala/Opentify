import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/library_repository.dart';
import '../../state/providers.dart';
import '../../state/glass_settings.dart';
import '../../state/grain_controller.dart';
import '../../state/theme_mode_controller.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/surface_card.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/spotify_import_report.dart';
import '../../routing/home_shell.dart' show navBottomInset;

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

  @override
  void dispose() {
    _pollTimer?.cancel();
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
    final scanStatus = ref.watch(scanStatusProvider);
    scanStatus.whenData(_syncPolling);
    return Scaffold(
      appBar: const SectionAppBar('Profil'),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(scanStatusProvider),
        child: ListView(
          padding: EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.md + navBottomInset(context)),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
            const _AppearanceCard(),
            const SizedBox(height: 12),
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
              title: 'Wrapped',
              description: 'Tvoje roky v hudbě od 2016 -- minuty, interpreti, skladby a žánry, '
                  'každou obrazovku jde sdílet jako obrázek. Zůstávají napořád.',
              buttonLabel: 'Otevřít',
              onPressed: () => context.push('/wrapped'),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Symbols.graphic_eq_rounded,
              title: 'Open Shazam',
              description: 'Pozná skladbu, která zrovna hraje kolem, a uloží ji do Poslechnout později '
                  'se značkou. Anonymně: Shazamu jde přes VPN jen otisk zvuku.',
              buttonLabel: 'Poznat skladbu',
              onPressed: () => context.push('/shazam'),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Symbols.music_note_rounded,
              title: 'Ladička',
              description: 'Ladička na kytaru -- standardní i alternativní ladění, struna se pozná '
                  'sama. Zvuk z mikrofonu zůstává v zařízení, nic se neodesílá.',
              buttonLabel: 'Ladit',
              onPressed: () => context.push('/tuner'),
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
      ref.invalidate(homeProvider);
      ref.invalidate(myPlaylistsProvider);
      messenger.hideCurrentSnackBar();
      if (!context.mounted) return;
      if (result.playlists.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('V souboru nebyly žádné playlisty ani skladby.')));
        return;
      }
      await showSpotifyImportReport(context, result);
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

    return SurfaceCard(
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

/// "Vzhled": Systém / Světlý / Tmavý (`themeModeProvider`, uložené per
/// zařízení, výchozí tmavý). Přepne okamžitě, téma i pozadí přejdou plynule.
class _AppearanceCard extends ConsumerWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Symbols.contrast_rounded),
              const SizedBox(width: 10),
              Text('Vzhled', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          GlassSegmentedControl<ThemeMode>(
            selected: ref.watch(themeModeProvider),
            onChanged: ref.read(themeModeProvider.notifier).set,
            segments: const [
              GlassSegment(value: ThemeMode.system, label: 'Systém', icon: Symbols.brightness_auto_rounded),
              GlassSegment(value: ThemeMode.light, label: 'Světlý', icon: Symbols.light_mode_rounded),
              GlassSegment(value: ThemeMode.dark, label: 'Tmavý', icon: Symbols.dark_mode_rounded),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Jemnější zrno', style: theme.textTheme.titleSmall),
                    Text(
                      'Slabší zrnitost pozadí, klidnější plochy.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GlassSwitch(
                value: ref.watch(fineGrainProvider),
                semanticLabel: 'Jemnější zrno',
                onChanged: ref.read(fineGrainProvider.notifier).set,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Skleněná tlačítka', style: theme.textTheme.titleSmall),
                    Text(
                      'Šipka zpět a tlačítka v hlavičce jako sklo místo tmavých kroužků.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GlassSwitch(
                value: ref.watch(glassButtonsProvider),
                semanticLabel: 'Skleněná tlačítka',
                onChanged: ref.read(glassButtonsProvider.notifier).set,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Lom skla (test)', style: theme.textTheme.titleSmall),
                    Text(
                      'Mini přehrávač a lišta lámou obsah pod sebou jako Liquid Glass. Vypni, kdyby trhaly nebo zčernaly obaly.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GlassSwitch(
                value: ref.watch(liquidGlassProvider),
                semanticLabel: 'Lom skla (test)',
                onChanged: ref.read(liquidGlassProvider.notifier).set,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Zrno na skle', style: theme.textTheme.titleSmall),
                    Text(
                      'Jemná textura na lištách a panelech, stejná jako na pozadí.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GlassSwitch(
                value: ref.watch(glassGrainProvider),
                semanticLabel: 'Zrno na skle',
                onChanged: ref.read(glassGrainProvider.notifier).set,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Tón skla', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          GlassSegmentedControl<GlassToneMode>(
            selected: ref.watch(glassToneProvider),
            onChanged: ref.read(glassToneProvider.notifier).set,
            segments: const [
              GlassSegment(value: GlassToneMode.auto, label: 'Podle motivu', icon: Symbols.brightness_auto_rounded),
              GlassSegment(value: GlassToneMode.light, label: 'Světlé', icon: Symbols.light_mode_rounded),
              GlassSegment(value: GlassToneMode.dark, label: 'Tmavé', icon: Symbols.dark_mode_rounded),
            ],
          ),
          const SizedBox(height: 12),
          _GlassSlider(
            title: 'Mléčnost skla',
            subtitle: 'Jak moc sklo rozmazává obsah pod sebou.',
            left: 'Čiré',
            right: 'Mléčné',
            provider: glassFrostProvider,
          ),
          const SizedBox(height: 8),
          _GlassSlider(
            title: 'Síla tónu',
            subtitle: 'Jak moc je sklo zabarvené -- silnější tón líp odliší lišty od pozadí.',
            left: 'Slabý',
            right: 'Silný',
            provider: glassTintProvider,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tón v barvě skladby', style: theme.textTheme.titleSmall),
                    Text(
                      'Sklo se zabarví barvou hrající skladby místo šedé (bílé ve světlém režimu).',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GlassSwitch(
                value: ref.watch(glassAccentTintProvider),
                semanticLabel: 'Tón v barvě skladby',
                onChanged: ref.read(glassAccentTintProvider.notifier).set,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Jezdec nastavení skla (Profil › Vzhled).
class _GlassSlider extends ConsumerWidget {
  const _GlassSlider({
    required this.title,
    required this.subtitle,
    required this.left,
    required this.right,
    required this.provider,
  });

  final String title;
  final String subtitle;
  final String left;
  final String right;
  final StateNotifierProvider<GlassSliderController, double> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Row(
          children: [
            Text(left, style: theme.textTheme.labelSmall),
            Expanded(
              child: Slider(
                value: ref.watch(provider),
                semanticFormatterCallback: (v) => '$title ${(v * 100).round()} %',
                onChanged: ref.read(provider.notifier).preview,
                onChangeEnd: (_) => ref.read(provider.notifier).save(),
              ),
            ),
            Text(right, style: theme.textTheme.labelSmall),
          ],
        ),
      ],
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
    return SurfaceCard(
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
            child: GlassButton(label: buttonLabel, compact: true, onPressed: onPressed),
          ),
        ],
      ),
    );
  }
}
