import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart' show ApiException;
import '../../data/library_repository.dart';
import '../../state/providers.dart';
import '../../state/glass_settings.dart';
import '../../state/auth_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../state/grain_controller.dart';
import '../../state/theme_mode_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/shapes.dart';
import '../../theme/glass_tokens.dart' show Expressive, Motion;
import '../../widgets/glass/glass.dart';
import '../../widgets/surface_card.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/spotify_import_report.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import 'profiles_section.dart';
import '../../core/share_image.dart' show shareFile;

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

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('Připravuju export…')));
    try {
      final bytes = await ref.read(apiClientProvider).getBytes('/library/export');
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      messenger?.hideCurrentSnackBar();
      await shareFile(bytes, fileName: 'opentify-export-$stamp.zip', mimeType: 'application/zip');
    } catch (_) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(const SnackBar(content: Text('Export se nepodařil.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scanStatus = ref.watch(scanStatusProvider);
    scanStatus.whenData(_syncPolling);
    final isAdmin = ref.watch(authProvider).valueOrNull?.user?.role == 'admin';
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
            // Admin jedná za jiný profil -- pruh se "Zpět na můj".
            const ActingAsBanner(),
            // Rychlý přístup nahoře (živě chtěné): Wrapped, Shazam, ladička.
            Row(
              children: [
                Expanded(
                  child: _QuickButton(
                      icon: Symbols.equalizer_rounded, label: 'Wrapped', onTap: () => context.push('/wrapped')),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _QuickButton(
                      icon: Symbols.graphic_eq_rounded, label: 'Shazam', onTap: () => context.push('/shazam')),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _QuickButton(
                      icon: Symbols.music_note_rounded, label: 'Ladička', onTap: () => context.push('/tuner')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Sbalitelné skupiny místo jednoho dlouhého seznamu karet (pro
            // tátu: otevře jen to, co potřebuje; stav se pamatuje).
            const _Section(
              id: 'appearance',
              icon: Symbols.contrast_rounded,
              title: 'Vzhled',
              summary: 'Motiv, sklo nebo plné plochy, zrno',
              initiallyOpen: true,
              child: _AppearanceSettings(),
            ),
            const SizedBox(height: 12),
            _Section(
              id: 'music',
              icon: Symbols.library_music_rounded,
              title: 'Moje hudba',
              summary: isAdmin
                  ? 'Import ze Spotify, export, kontrola stažených, lokální knihovna'
                  : 'Import ze Spotify, export dat',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ActionRow(
                    icon: Symbols.cloud_upload_rounded,
                    title: 'Import ze Spotify',
                    description:
                        'Nahraj export playlistů (ZIP s CSV, např. z Exportify) nebo '
                        'YourLibrary.json z oficiálního Spotify exportu. Liked Songs se '
                        'použijí pro tvůj denní mix, ostatní playlisty se naimportují '
                        'pod svým jménem. ZIP s historií poslechů (Extended streaming history) '
                        'nahraje poslechy pro Wrapped a mixy.',
                    buttonLabel: 'Vybrat soubor…',
                    onPressed: () => _importFromSpotify(context),
                  ),
                  _ActionRow(
                    icon: Symbols.ios_share_rounded,
                    title: 'Exportovat moje data',
                    description: 'Oblíbené, playlisty, historie poslechů a seznam „Na později“ v jednom ZIPu. '
                        'CSV jde nahrát do TuneMyMusic a převést do Spotify, Apple Music a dalších.',
                    buttonLabel: 'Exportovat',
                    onPressed: () => _export(context),
                  ),
                  if (isAdmin) ...[
                    _ActionRow(
                      icon: Symbols.fact_check_rounded,
                      title: 'Kontrola stažených',
                      description: 'Skladby, u kterých nesedí délka nebo Shazam slyší něco jiného. '
                          'Pusť si je a rozhodni: je to dobře, nebo stáhnout znovu.',
                      buttonLabel: 'Projít',
                      onPressed: () => context.push('/verify-downloads'),
                    ),
                    _ActionRow(
                      icon: Symbols.folder_rounded,
                      title: 'Lokální knihovna',
                      description:
                          'Projde hudební soubory namapované z hostitele (proměnná MUSIC_DIR '
                          'v .env), spáruje je na MusicBrainz podle tagů a dotáhne obaly. '
                          'Běží na pozadí, u větší knihovny to chvíli potrvá.',
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
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Profily (jen admin; ostatní sekci nevidí).
            const ProfilesSection(),
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
      final imported = await ref.read(libraryRepositoryProvider).importSpotifyLibrary(bytes, file.name);
      ref.invalidate(likedSongsProvider);
      ref.invalidate(homeProvider);
      ref.invalidate(myPlaylistsProvider);
      messenger.hideCurrentSnackBar();
      if (!context.mounted) return;
      if (imported.historyListens != null) {
        messenger.showSnackBar(SnackBar(
          content: Text('Historie poslechů nahraná (${imported.historyListens} poslechů) – Wrapped a mixy '
              'se podle ní přepočítají.'),
        ));
        return;
      }
      final result = imported.result!;
      if (result.playlists.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('V souboru nebyly žádné playlisty ani skladby.')));
        return;
      }
      await showSpotifyImportReport(context, result);
    } catch (e) {
      final detail = e is ApiException ? e.detail : null;
      messenger.showSnackBar(SnackBar(content: Text(detail ?? 'Import se nepodařil. Zkontroluj, že je to export ze Spotify.')));
    }
  }

  Future<void> _startScan(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(libraryRepositoryProvider).startScan();
      ref.invalidate(scanStatusProvider);
    } catch (e) {
      final detail = e is ApiException ? e.detail : null;
      messenger.showSnackBar(SnackBar(content: Text(detail ?? 'Sken se nepodařilo spustit.')));
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

/// Profil › Vzhled: motiv (Systém / Světlý / Tmavý), styl ploch (Liquid
/// Glass / Bez skla) a zrno. Jemné ladění skla je ve vnořené sbalené
/// skupině -- v režimu "Bez skla" se vůbec neukazuje.
class _AppearanceSettings extends ConsumerWidget {
  const _AppearanceSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final glassOff = ref.watch(glassOffProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Motiv', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        GlassSegmentedControl<ThemeMode>(
          selected: ref.watch(themeModeProvider),
          onChanged: ref.read(themeModeProvider.notifier).set,
          segments: const [
            GlassSegment(value: ThemeMode.system, label: 'Systém', icon: Symbols.brightness_auto_rounded),
            GlassSegment(value: ThemeMode.light, label: 'Světlý', icon: Symbols.light_mode_rounded),
            GlassSegment(value: ThemeMode.dark, label: 'Tmavý', icon: Symbols.dark_mode_rounded),
          ],
        ),
        const SizedBox(height: 16),
        Text('Styl', style: theme.textTheme.titleSmall),
        Text(
          glassOff
              ? 'Plné plochy bez průhlednosti – vyšší kontrast a lehčí pro starší telefony.'
              : 'Průhledné sklo s rozmazáním a lomem, jako v iOS.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        GlassSegmentedControl<bool>(
          selected: glassOff,
          onChanged: ref.read(glassOffProvider.notifier).set,
          segments: const [
            GlassSegment(value: false, label: 'Liquid Glass', icon: Symbols.blur_on_rounded),
            GlassSegment(value: true, label: 'Bez skla', icon: Symbols.crop_square_rounded),
          ],
        ),
        const SizedBox(height: 12),
        _SwitchRow(
          title: 'Jemnější zrno',
          subtitle: 'Slabší zrnitost pozadí, klidnější plochy.',
          value: ref.watch(fineGrainProvider),
          onChanged: ref.read(fineGrainProvider.notifier).set,
        ),
        if (!glassOff) ...[
          const SizedBox(height: 8),
          const _Section(
            id: 'glass',
            icon: Symbols.tune_rounded,
            title: 'Nastavení skla',
            summary: 'Tón, mléčnost, lom, skleněná tlačítka',
            nested: true,
            child: _GlassTuning(),
          ),
        ],
      ],
    );
  }
}

class _GlassTuning extends ConsumerWidget {
  const _GlassTuning();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchRow(
          title: 'Skleněná tlačítka',
          subtitle: 'Šipka zpět a tlačítka v hlavičce jako sklo místo tmavých kroužků.',
          value: ref.watch(glassButtonsProvider),
          onChanged: ref.read(glassButtonsProvider.notifier).set,
        ),
        const SizedBox(height: 12),
        _SwitchRow(
          title: 'Lom skla',
          subtitle: 'Mini přehrávač a lišta lámou obsah pod sebou. Vypni, kdyby trhaly nebo zčernaly obaly.',
          value: ref.watch(liquidGlassProvider),
          onChanged: ref.read(liquidGlassProvider.notifier).set,
        ),
        const SizedBox(height: 12),
        _SwitchRow(
          title: 'Zrno na skle',
          subtitle: 'Jemná textura na lištách a panelech, stejná jako na pozadí.',
          value: ref.watch(glassGrainProvider),
          onChanged: ref.read(glassGrainProvider.notifier).set,
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
          subtitle: 'Jak moc je sklo zabarvené – silnější tón líp odliší lišty od pozadí.',
          left: 'Slabý',
          right: 'Silný',
          provider: glassTintProvider,
        ),
        const SizedBox(height: 8),
        _GlassSlider(
          title: 'Tmavost tónu',
          subtitle: 'Jak tmavé je sklo.',
          left: 'Světlejší',
          right: 'Tmavší',
          provider: glassDarknessProvider,
        ),
        const SizedBox(height: 8),
        _GlassSlider(
          title: 'Barevnost tónu',
          subtitle: 'Kolik barvy skladby sklo nese – vlevo skoro šedé, vpravo barevné.',
          left: 'Šedé',
          right: 'Barevné',
          provider: glassColorfulnessProvider,
        ),
        const SizedBox(height: 8),
        _SwitchRow(
          title: 'Tón v barvě skladby',
          subtitle: 'Sklo se zabarví barvou hrající skladby místo šedé (bílé ve světlém režimu).',
          value: ref.watch(glassAccentTintProvider),
          onChanged: ref.read(glassAccentTintProvider.notifier).set,
        ),
        if (ref.watch(glassAccentTintProvider)) ...[
          const SizedBox(height: 12),
          Text('Barva tónu', style: theme.textTheme.titleSmall),
          Text(
            'Hlavní ladí s pozadím, kontrastní je výrazná barva z obalu.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          GlassSegmentedControl<bool>(
            segments: const [
              GlassSegment(value: true, label: 'Hlavní'),
              GlassSegment(value: false, label: 'Kontrastní'),
            ],
            selected: ref.watch(glassTintMainProvider),
            onChanged: ref.read(glassTintMainProvider.notifier).set,
          ),
        ],
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.title, required this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        GlassSwitch(value: value, semanticLabel: title, onChanged: onChanged),
      ],
    );
  }
}

/// Otevřené skupiny Profilu (pamatuje se v zařízení); `null` = ještě
/// neuloženo, platí výchozí stav skupin.
class _OpenSections extends StateNotifier<Set<String>?> {
  _OpenSections() : super(null) {
    _load();
  }

  static const _prefKey = 'profile.open_sections';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_prefKey);
      if (saved != null && mounted) state = saved.toSet();
    } catch (_) {}
  }

  Future<void> toggle(String id, Set<String> defaults) async {
    final current = {...(state ?? defaults)};
    if (!current.remove(id)) current.add(id);
    state = current;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, current.toList());
    } catch (_) {}
  }
}

final _openSectionsProvider = StateNotifierProvider<_OpenSections, Set<String>?>((ref) => _OpenSections());

/// Skupiny otevřené, dokud si uživatel nic nepřepnul.
const _defaultOpen = {'appearance'};

/// Sbalitelná skupina: hlavička (ikona, název, co v ní je) a obsah.
class _Section extends ConsumerWidget {
  const _Section({
    required this.id,
    required this.icon,
    required this.title,
    required this.summary,
    required this.child,
    // ignore: unused_element_parameter
    this.initiallyOpen = false,
    this.nested = false,
  });

  final String id;
  final IconData icon;
  final String title;
  final String summary;
  final Widget child;
  final bool initiallyOpen;
  final bool nested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = (ref.watch(_openSectionsProvider) ?? _defaultOpen).contains(id);
    final header = InkWell(
      borderRadius: BorderRadius.circular(AppRadii.md),
      onTap: () => ref.read(_openSectionsProvider.notifier).toggle(id, _defaultOpen),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: nested ? 8 : 4),
        child: Row(
          children: [
            Icon(icon, size: nested ? 20 : 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: nested ? theme.textTheme.titleSmall : theme.textTheme.titleMedium),
                  if (!open)
                    Text(summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: Motion.state.duration,
              curve: Motion.state,
              child: const Icon(Symbols.expand_more_rounded),
            ),
          ],
        ),
      ),
    );
    final body = AnimatedSize(
      duration: Motion.state.duration,
      curve: Motion.state,
      alignment: Alignment.topCenter,
      child: open
          ? Padding(padding: EdgeInsets.only(top: nested ? 8 : 12), child: child)
          : const SizedBox(width: double.infinity),
    );
    final column = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, body]);
    return nested ? column : SurfaceCard(child: column);
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

/// Položka ve skupině Profilu: ikona, název, popis a tlačítko.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 4),
          Text(description, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: GlassButton(label: buttonLabel, compact: true, onPressed: onPressed),
          ),
        ],
      ),
    );
  }
}

/// Velké tónové tlačítko nahoře v Profilu (ikona nad popiskem).
class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = AppShapes.of(Expressive.cornerLarge);
    return GlassPressable(
      onPressed: onTap,
      shape: shape,
      minSize: Size.zero,
      semanticLabel: label,
      // Plná šířka -- GlassPressable dítě centruje a zúžilo by ho na ikonu.
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: scheme.secondaryContainer),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 30, color: scheme.onSecondaryContainer),
              const SizedBox(height: 6),
              Text(label, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSecondaryContainer)),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
