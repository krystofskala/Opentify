import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart' show ApiException;
import '../../data/library_repository.dart';
import '../../state/providers.dart';
import '../../state/liked_songs_controller.dart' show likedSongsControllerProvider;
import '../../state/glass_settings.dart';
import '../../state/auth_controller.dart';
import 'home_genres_sheet.dart';
import '../home/home_layout_sheet.dart';
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
import '../../core/device_token.dart' show clearDeviceToken;
import '../../core/profile_prefs.dart' show clearProfilePrefs;
import '../../core/page_location.dart' show reloadPage;
import '../../core/share_image.dart' show shareFile;
import '../../core/now_playing_activity.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import '../../widgets/toast.dart';
import '../artist/artist_support.dart' show openExternal;
import '../../core/app_update.dart';
import '../../widgets/app_update_sheet.dart';

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
    showToast(messenger, 'Připravuju export…');
    try {
      final bytes = await ref.read(apiClientProvider).getBytes('/library/export');
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      messenger?.hideCurrentSnackBar();
      await shareFile(bytes, fileName: 'opentify-export-$stamp.zip', mimeType: 'application/zip');
    } catch (_) {
      messenger?.hideCurrentSnackBar();
      showToast(messenger, 'Export se nepodařil.');
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
                  // Verze appky hned pod nadpisem -- ať je vidět, jestli update dorazil.
                  const _AppVersion(),
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
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _QuickButton(
                            icon: Symbols.join_inner_rounded, label: 'Blend', onTap: () => context.push('/blends')),
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
                    id: 'home',
                    icon: Symbols.home_rounded,
                    title: 'Domů',
                    summary: 'Pořadí sekcí, skryté sekce, žánry',
                    child: Column(
                      children: [
                        _ActionRow(
                          icon: Symbols.tune_rounded,
                          title: 'Upravit Domů',
                          description: 'Přetažením změníš pořadí sekcí na Domů, vypínačem je skryješ.',
                          buttonLabel: 'Upravit',
                          onPressed: () => showHomeLayoutSheet(context),
                        ),
                        const _ShareListeningRow(),
                        _ActionRow(
                          icon: Symbols.category_rounded,
                          title: 'Žánry, nálady a soundtracky na Domů',
                          description: 'Vybrané žánry dostanou na Domů vlastní řadu. '
                              'Bez výběru je Domů stejné jako pro ostatní.',
                          buttonLabel: 'Vybrat',
                          onPressed: () => showHomeGenresSheet(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Section(
                    id: 'music',
                    icon: Symbols.library_music_rounded,
                    title: 'Moje hudba',
                    summary: isAdmin
                        ? 'Import ze Spotify, export, kontrola stažených, lokální knihovna'
                        : 'Import ze Spotify, export dat, ListenBrainz',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ActionRow(
                          icon: Symbols.explore_rounded,
                          title: 'Objevy',
                          description: 'Kolik nových skladeb tě chytlo a odkud přišly – z mixů, alb, hledání, rádia…',
                          buttonLabel: 'Otevřít',
                          onPressed: () => context.push('/discoveries'),
                        ),
                        _ActionRow(
                          icon: Symbols.history_rounded,
                          title: 'Historie',
                          description: 'Posledních 100 skladeb, které sis v appce poslechl, a odkud hrály.',
                          buttonLabel: 'Otevřít',
                          onPressed: () => context.push('/history'),
                        ),
                        _ActionRow(
                          icon: Symbols.cloud_upload_rounded,
                          title: 'Import ze Spotify, Apple Music a YouTube Music',
                          description: 'Spotify: export playlistů (ZIP s CSV, např. z Exportify) nebo '
                              'YourLibrary.json z oficiálního exportu -- Liked Songs pro denní mix, '
                              'ostatní playlisty pod svým jménem. ZIP s historií poslechů (Extended '
                              'streaming history) nahraje poslechy pro Wrapped a mixy.\n'
                              'YouTube Music: Google Takeout › YouTube a YouTube Music › historie, '
                              'formát JSON (v Takeoutu přepnout z HTML) – poslechy se přidají k těm ze Spotify.\n'
                              'Apple Music: privacy.apple.com › kopie dat › Média a nákupy Apple – nahraj ZIP '
                              '„Informace o mediálních službách Apple“ (část 1). Poslechy i knihovna.',
                          buttonLabel: 'Vybrat soubor…',
                          onPressed: () => _importFromSpotify(context),
                        ),
                        const _ImportedHistoryLine(),
                        _ActionRow(
                          icon: Symbols.archive_rounded,
                          title: 'Exportovat moje data',
                          description: 'Oblíbené, playlisty, historie poslechů a seznam „Na později“ v jednom ZIPu. '
                              'CSV jde nahrát do TuneMyMusic a převést do Spotify, Apple Music a dalších.',
                          buttonLabel: 'Exportovat',
                          onPressed: () => _export(context),
                        ),
                        const _ListenBrainzRow(),
                        const _LastfmRow(),
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
                            icon: Symbols.inbox_rounded,
                            title: 'Žádosti o stažení',
                            description: 'Co si kdo chce stáhnout a musíš schválit (velké audioknihy, audioknihy z internetu). '
                                'Stejné jako tlačítka v upozornění na telefonu.',
                            buttonLabel: 'Otevřít',
                            onPressed: () => context.push('/download-requests'),
                          ),
                          _ActionRow(
                            icon: Symbols.speed_rounded,
                            title: 'Test přehrávání',
                            description: 'Appka sama pustí asi 20 skladeb jako ty a změří, za jak dlouho začnou hrát. '
                                'Výsledek dostane server, do poslechů se nic nepočítá.',
                            buttonLabel: 'Otevřít',
                            onPressed: () => context.push('/playback-test'),
                          ),
                          _ActionRow(
                            icon: Symbols.folder_rounded,
                            title: 'Lokální knihovna',
                            description: 'Projde hudební soubory namapované z hostitele (proměnná MUSIC_DIR '
                                'v .env), spáruje je na MusicBrainz podle tagů a dotáhne obaly. '
                                'Běží na pozadí, u větší knihovny to chvíli potrvá.',
                            buttonLabel: scanStatus.valueOrNull?.isRunning == true ? 'Skenuji…' : 'Skenovat knihovnu',
                            onPressed: scanStatus.valueOrNull?.isRunning == true ? null : () => _startScan(context),
                          ),
                          scanStatus.maybeWhen(
                            data: (status) => status.status == 'idle'
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(top: 12), child: _ScanStatusCard(status: status)),
                            orElse: () => const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Profily (jen admin; ostatní sekci nevidí).
                  const ProfilesSection(),
                  const SizedBox(height: 12),
                  const _LogoutButton(),
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
    showToast(messenger, 'Importuji…');
    try {
      final imported = await ref.read(libraryRepositoryProvider).importSpotifyLibrary(bytes, file.name);
      ref.invalidate(likedSongsProvider);
      // Importované lajky do srdíček hned, ne až po restartu appky.
      unawaited(ref.read(likedSongsControllerProvider.notifier).refresh());
      ref.invalidate(homeProvider);
      ref.invalidate(myPlaylistsProvider);
      messenger.hideCurrentSnackBar();
      if (!context.mounted) return;
      if (imported.historyListens != null) {
        ref.invalidate(importedHistoryProvider);
        final name = switch (imported.platform) {
          'ytmusic' => 'YouTube Music',
          'applemusic' => 'Apple Music',
          _ => 'Spotify',
        };
        showToast(
          messenger,
          [
            if (imported.historyListens! > 0)
              '$name: ${imported.historyListens} poslechů nahráno – Wrapped a mixy se přepočítají',
            if ((imported.libraryTracks ?? 0) > 0)
              'knihovna $name (${imported.libraryTracks} skladeb) je v playlistu „$name · Knihovna“',
          ].join('; '),
        );
        return;
      }
      final result = imported.result!;
      if (result.playlists.isEmpty) {
        showToast(messenger, 'V souboru nebyly žádné playlisty ani skladby.');
        return;
      }
      await showSpotifyImportReport(context, result);
    } catch (e) {
      final detail = e is ApiException ? e.detail : null;
      showToast(messenger,
          detail ?? 'Import se nepodařil. Zkontroluj, že je to export ze Spotify nebo z Google Takeoutu (JSON).');
    }
  }

  Future<void> _startScan(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(libraryRepositoryProvider).startScan();
      ref.invalidate(scanStatusProvider);
    } catch (e) {
      final detail = e is ApiException ? e.detail : null;
      showToast(messenger, detail ?? 'Sken se nepodařilo spustit.');
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
        // Na širokém displeji ne přes celou šířku.
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints.tightFor(width: 520),
            child: GlassSegmentedControl<ThemeMode>(
              selected: ref.watch(themeModeProvider),
              onChanged: ref.read(themeModeProvider.notifier).set,
              segments: const [
                GlassSegment(value: ThemeMode.system, label: 'Systém', icon: Symbols.brightness_auto_rounded),
                GlassSegment(value: ThemeMode.light, label: 'Světlý', icon: Symbols.light_mode_rounded),
                GlassSegment(value: ThemeMode.dark, label: 'Tmavý', icon: Symbols.dark_mode_rounded),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Styl', style: theme.textTheme.titleSmall),
        Text(
          glassOff
              ? 'Plné plochy bez průhlednosti – vyšší kontrast a lehčí pro starší telefony. Platí jen pro toto zařízení.'
              : 'Průhledné sklo s rozmazáním a lomem, jako v iOS. Platí jen pro toto zařízení.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        // Na širokém displeji ne přes celou šířku.
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints.tightFor(width: 520),
            child: GlassSegmentedControl<bool>(
              selected: glassOff,
              onChanged: ref.read(glassOffProvider.notifier).set,
              segments: const [
                GlassSegment(value: false, label: 'Liquid Glass', icon: Symbols.blur_on_rounded),
                GlassSegment(value: true, label: 'Bez skla', icon: Symbols.crop_square_rounded),
              ],
            ),
          ),
        ),
        if (systemGlassSupported && !glassOff) ...[
          const SizedBox(height: 12),
          _SwitchRow(
            title: 'Systémové sklo (iOS 26)',
            subtitle: 'Tab bar a mini přehrávač ze skutečného Liquid Glass jako v Apple Music – '
                'lom, lesk a barevný okraj kreslí iOS. Test, porovnej s naším sklem.',
            value: ref.watch(systemGlassProvider),
            onChanged: ref.read(systemGlassProvider.notifier).set,
          ),
        ],
        const SizedBox(height: 16),
        Text('Pozadí', style: theme.textTheme.titleSmall),
        Text(
          ref.watch(backgroundV2Provider)
              ? 'Víc barev obalu najednou, plynulejší reakce na posouvání a jemné dýchání podle hlasitosti skladby.'
              : 'Původní tekuté pozadí v barvách obalu.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints.tightFor(width: 520),
            child: GlassSegmentedControl<bool>(
              selected: ref.watch(backgroundV2Provider),
              onChanged: ref.read(backgroundV2Provider.notifier).set,
              segments: const [
                GlassSegment(value: false, label: 'Klasické', icon: Symbols.gradient_rounded),
                GlassSegment(value: true, label: 'Nové (beta)', icon: Symbols.auto_awesome_rounded),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _SwitchRow(
          title: 'Omezit animace',
          subtitle: 'Méně pohybu: bez pružin, plynutí a samostatného posouvání. Platí jen pro toto zařízení '
              '(zapne se i samo, když máš omezení pohybu v systému).',
          value: ref.watch(reducedMotionProvider),
          onChanged: ref.read(reducedMotionProvider.notifier).set,
        ),
        const SizedBox(height: 12),
        Text('Zrno na pozadí', style: theme.textTheme.titleSmall),
        Text(
          'Jemná filmová zrnitost. Poloviční = stejné zrno, ale slabší; vypnuté = úplně hladké plochy.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints.tightFor(width: 520),
            child: GlassSegmentedControl<int>(
              // 2 = plné, 1 = poloviční, 0 = vypnuté
              selected: ref.watch(noGrainProvider) ? 0 : (ref.watch(halfGrainProvider) ? 1 : 2),
              onChanged: (level) {
                ref.read(noGrainProvider.notifier).set(level == 0);
                ref.read(halfGrainProvider.notifier).set(level == 1);
              },
              segments: const [
                GlassSegment(value: 2, label: 'Plné', icon: Symbols.grain_rounded),
                GlassSegment(value: 1, label: 'Poloviční', icon: Symbols.blur_on_rounded),
                GlassSegment(value: 0, label: 'Vypnuté', icon: Symbols.crop_square_rounded),
              ],
            ),
          ),
        ),
        // Jen iOS appka: karta s obalem ve "fun shape" na zámku a v Dynamic
        // Islandu. Výchozí vypnuto -- systémový přehrávač na zámku stačí.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) ...[
          const SizedBox(height: 12),
          StatefulBuilder(
            builder: (context, setState) => _SwitchRow(
              title: 'Live Activity',
              subtitle:
                  'Karta s obalem ve tvaru na zamčené obrazovce a v Dynamic Islandu (vedle systémového přehrávače).',
              value: NowPlayingActivity.enabled,
              onChanged: (v) async {
                await NowPlayingActivity.setEnabled(v);
                setState(() {});
              },
            ),
          ),
        ],
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
/// Kolik poslechů je nahraných z které služby (rozlišení Spotify / YouTube
/// Music / Apple Music -- dohromady se sčítají ve Wrapped a mixech).
final importedHistoryProvider = FutureProvider.autoDispose<Map<String, int>>((ref) async {
  final json = await ref.read(apiClientProvider).getJson('/library/history-imports');
  return {for (final e in json.entries) e.key: (e.value as num).toInt()};
});

class _ImportedHistoryLine extends ConsumerWidget {
  const _ImportedHistoryLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(importedHistoryProvider).valueOrNull ?? const {};
    const names = {'spotify': 'Spotify', 'ytmusic': 'YouTube Music', 'applemusic': 'Apple Music'};
    final parts = [
      for (final e in names.entries)
        if ((counts[e.key] ?? 0) > 0) '${e.value}: ${counts[e.key]} poslechů',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 30, bottom: AppSpacing.xs),
      child: Text(
        'Nahraná historie – ${parts.join(' · ')}',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

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

/// "Opentify 0.1.11 · iOS" pod nadpisem Profilu.
class _AppVersion extends StatelessWidget {
  const _AppVersion();

  static final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox(height: 18);
        final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
        final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            children: [
              Text('Opentify ${info.version} · $platform', style: style),
              // Android: aktualizace z GitHubu (iOS řeší SideStore).
              if (appUpdatesSupported)
                GestureDetector(
                  onTap: () => checkAppUpdateManually(context),
                  child: Text(' · Zkontrolovat aktualizace',
                      style: style?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Vlastní Last.fm účet profilu: scrobbly jen tohohle profilu a jen od
/// připojení. Ostatní profily bez vlastního účtu na Last.fm nic neposílají.
class _LastfmRow extends ConsumerWidget {
  const _LastfmRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).valueOrNull;
    if (auth?.acting == null) return const SizedBox.shrink();
    final user = auth!.lastfmUser;
    return _ActionRow(
      icon: Symbols.graphic_eq_rounded,
      title: user == null ? 'Last.fm' : 'Last.fm · $user',
      description: user == null
          ? 'Připoj svůj Last.fm a poslechy z Opentify se ti budou zapisovat (scrobblovat) do tvého profilu.'
          : 'Poslechy tohohle profilu se scrobblují do účtu $user.',
      buttonLabel: user == null ? 'Připojit…' : 'Odpojit',
      onPressed: () => user == null ? _connect(context, ref) : _disconnect(context, ref),
    );
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(apiClientProvider);
    final String token;
    final String url;
    try {
      final start = await api.postJson('/auth/me/lastfm/start');
      token = start['token'] as String;
      url = start['url'] as String;
    } catch (e) {
      showToast(
          messenger, e is ApiException ? (e.detail ?? 'Last.fm teď nejde připojit.') : 'Last.fm teď nejde připojit.');
      return;
    }
    if (!context.mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Připojit Last.fm'),
        // Odkaz otevře až klepnutí (Safari jinak okno po síťovém dotazu zablokuje).
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Otevři last.fm a klepni na „Yes, allow access“.\n2. Vrať se sem a dej Hotovo.'),
            const SizedBox(height: AppSpacing.sm),
            GlassButton(
              label: 'Otevřít last.fm',
              icon: Symbols.open_in_new_rounded,
              style: GlassButtonStyle.tonal,
              compact: true,
              onPressed: () => openExternal(url),
            ),
          ],
        ),
        actions: [
          GlassButton(
            label: 'Zrušit',
            style: GlassButtonStyle.plain,
            compact: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          GlassButton(
            label: 'Hotovo',
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (done != true) return;
    try {
      final json = await api.postJson('/auth/me/lastfm/finish', body: {'token': token});
      ref.invalidate(authProvider);
      showToast(messenger, 'Last.fm připojen jako ${json['lastfmUser']}.');
    } catch (e) {
      showToast(messenger, e is ApiException ? (e.detail ?? 'Připojení se nepodařilo.') : 'Připojení se nepodařilo.');
    }
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).deleteJson('/auth/me/lastfm');
      ref.invalidate(authProvider);
      showToast(messenger, 'Last.fm odpojen, poslechy se tam už neposílají.');
    } catch (_) {
      showToast(messenger, 'Odpojení se nepodařilo.');
    }
  }
}

/// Vlastní ListenBrainz účet profilu: poslechy, "právě hraje" a srdíčka
/// tohohle profilu jdou do JEHO účtu (export dat, doporučení LB podle toho,
/// co poslouchá). Bez připojení se nikam neposílají.
class _ListenBrainzRow extends ConsumerWidget {
  const _ListenBrainzRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).valueOrNull;
    if (auth?.acting == null) return const SizedBox.shrink();
    final lbUser = auth!.listenbrainzUser;
    return _ActionRow(
      icon: Symbols.podcasts_rounded,
      title: lbUser == null ? 'ListenBrainz' : 'ListenBrainz · $lbUser',
      description: lbUser == null
          ? 'Připoj svůj účet a poslechy se ti budou ukládat na ListenBrainz – i ty, '
              'co už tu máš. Token najdeš na listenbrainz.org › Settings.'
          : 'Poslechy a srdíčka tohohle profilu jdou do tvého účtu $lbUser.',
      buttonLabel: lbUser == null ? 'Připojit…' : 'Odpojit',
      onPressed: () => lbUser == null ? _connect(context, ref) : _disconnect(context, ref),
    );
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Připojit ListenBrainz'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(hintText: 'User token z listenbrainz.org/settings'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          GlassButton(
            label: 'Zrušit',
            style: GlassButtonStyle.plain,
            compact: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          GlassButton(
            label: 'Připojit',
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    if (token == null || token.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = await ref.read(apiClientProvider).putJson('/auth/me/listenbrainz', body: {'token': token});
      ref.invalidate(authProvider);
      showToast(messenger, 'Připojeno jako ${json['listenbrainzUser']}.');
    } catch (e) {
      final detail = e is ApiException ? e.detail : null;
      showToast(messenger, detail ?? 'Připojení se nepodařilo.');
    }
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).deleteJson('/auth/me/listenbrainz');
      ref.invalidate(authProvider);
      showToast(messenger, 'ListenBrainz odpojen, poslechy se tam už neposílají.');
    } catch (_) {
      showToast(messenger, 'Odpojení se nepodařilo.');
    }
  }
}

/// Odhlásit tohle zařízení (jen v režimu přihlašování jménem a heslem).
class _LogoutButton extends ConsumerWidget {
  const _LogoutButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).valueOrNull;
    if (auth?.mode != 'login' || auth?.user == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Přihlásit další vlastní zařízení: kód k jménu a heslu. Kódy
        // vydává jen admin (ostatní profily dostanou kód od něj).
        if (auth!.user!.role == 'admin')
          GlassButton(
          label: 'Přidat zařízení',
          icon: Symbols.devices_rounded,
          compact: true,
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            try {
              final json = await ref.read(apiClientProvider).postJson('/auth/pair-code');
              if (context.mounted) await showPairCodeDialog(context, auth.user!.name, json);
            } catch (_) {
              showToast(messenger, 'Kód se nepodařilo vytvořit.');
            }
          },
        ),
        GlassButton(
          label: 'Odhlásit se (${auth.user!.name})',
          icon: Symbols.logout_rounded,
          compact: true,
          onPressed: () async {
            // Omylem klepnuté odhlášení = znovu jméno a heslo (UX audit 7. 10.).
            final sure = await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                title: const Text('Odhlásit se?'),
                content: const Text('Na tomhle zařízení se pak znovu přihlásíš jménem a heslem.'),
                actions: [
                  GlassButton(
                    label: 'Zrušit',
                    style: GlassButtonStyle.plain,
                    compact: true,
                    onPressed: () => Navigator.of(dialog).pop(false),
                  ),
                  GlassButton(
                    label: 'Odhlásit',
                    destructive: true,
                    compact: true,
                    onPressed: () => Navigator.of(dialog).pop(true),
                  ),
                ],
              ),
            );
            if (sure != true) return;
            try {
              await ref.read(apiClientProvider).postJson('/auth/logout');
            } catch (_) {}
            await clearDeviceToken();
            // Další přihlášený nemá vidět frontu ani historii hledání.
            await clearProfilePrefs();
            ref.invalidate(authProvider);
            reloadPage();
          },
        ),
      ],
    );
  }
}

/// Profil › Domů: sdílet, co poslouchám, s ostatními profily (jejich sekce
/// "Co poslouchá rodina"). Ve výchozím stavu vypnuté.
class _ShareListeningRow extends ConsumerStatefulWidget {
  const _ShareListeningRow();

  @override
  ConsumerState<_ShareListeningRow> createState() => _ShareListeningRowState();
}

class _ShareListeningRowState extends ConsumerState<_ShareListeningRow> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    ref.read(apiClientProvider).getJson('/home/share-listening').then((json) {
      if (mounted) setState(() => _on = json['on'] as bool? ?? false);
    }).catchError((Object _) {
      if (mounted) setState(() => _on = false);
    });
  }

  Future<void> _set(bool on) async {
    setState(() => _on = on);
    try {
      await ref.read(apiClientProvider).putJson('/home/share-listening', body: {'on': on});
    } catch (_) {
      if (mounted) setState(() => _on = !on);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(Symbols.group_rounded),
      title: const Text('Sdílet, co poslouchám'),
      subtitle: Text(
        'Ostatní profily uvidí tvé poslední skladby v sekci „Co poslouchá rodina“.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      value: _on ?? false,
      onChanged: _on == null ? null : _set,
    );
  }
}
