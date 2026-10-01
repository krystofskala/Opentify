import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/state_views.dart' show SectionHeader;
import '../../widgets/toast.dart';

/// Odkazy "jak interpreta podpořit" (backend `/catalog/artists/{id}/support`
/// z MusicBrainz, s vyhledáváním tam, kde MusicBrainz odkaz nemá).
final artistSupportProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, artistId) {
  return ref.watch(catalogRepositoryProvider).getArtistSupport(artistId);
});

/// Otevře odkaz mimo appku (nová karta / Safari).
Future<void> openExternal(String url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');

/// Sekce "Podpořit umělce" na stránce interpreta: web, Bandcamp (většina
/// peněz jde přímo interpretovi), obchod/merch, vinyly a CD (Discogs),
/// koncerty (Bandsintown/Songkick) a charita jménem interpreta.
class ArtistSupportSection extends ConsumerWidget {
  const ArtistSupportSection({super.key, required this.artistId, required this.artistName});

  final String artistId;
  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(artistSupportProvider(artistId)).valueOrNull;
    if (data == null) return const SizedBox.shrink();
    String? s(String key) => data[key] as String?;
    final buttons = <Widget>[
      if (s('bandcamp') != null)
        _Link(icon: Symbols.storefront_rounded, label: 'Bandcamp', url: s('bandcamp')!)
      else if (s('bandcampSearch') != null)
        _Link(icon: Symbols.storefront_rounded, label: 'Hledat na Bandcampu', url: s('bandcampSearch')!),
      if (s('shop') != null) _Link(icon: Symbols.checkroom_rounded, label: 'Merch a obchod', url: s('shop')!),
      if (s('records') != null) _Link(icon: Symbols.album_rounded, label: 'Vinyly a CD', url: s('records')!),
      if (s('concerts') != null)
        _Link(
          icon: Symbols.confirmation_number_rounded,
          label: 'Koncerty (${s('concertsSource') ?? 'Songkick'})',
          url: s('concerts')!,
        ),
      if (s('web') != null) _Link(icon: Symbols.language_rounded, label: 'Web', url: s('web')!),
      GlassButton(
        label: 'Charita jeho jménem',
        icon: Symbols.volunteer_activism_rounded,
        style: GlassButtonStyle.tonal,
        compact: true,
        onPressed: () => showCharitySheet(context, artistName),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Podpořit umělce'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: buttons),
          ),
        ],
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.icon, required this.label, required this.url});

  final IconData icon;
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => GlassButton(
        label: label,
        icon: icon,
        style: GlassButtonStyle.tonal,
        compact: true,
        onPressed: () => openExternal(url),
      );
}

/// Hudební charity; dar se posílá na jejich stránce, věnování "jménem
/// interpreta" se vkládá do poznámky k daru (appka ho zkopíruje).
const _charities = [
  (
    name: 'Nadace Život umělce',
    about: 'Česká nadace – pomáhá umělcům v nouzi, seniorům i mladým.',
    url: 'https://www.nadace-zivot-umelce.cz/',
  ),
  (
    name: 'Help Musicians',
    about: 'Britská charita pro hudebníky (zdraví, nouze, začátky kariéry).',
    url: 'https://www.helpmusicians.org.uk/',
  ),
  (
    name: 'MusiCares',
    about: 'Americká charita Grammy – zdraví a sociální pomoc hudebníkům.',
    url: 'https://www.musicares.org/',
  ),
];

Future<void> showCharitySheet(BuildContext context, String artistName) {
  return showGlassSheet(
    context,
    builder: (context) {
      final theme = Theme.of(context);
      final dedication = 'Dar jménem $artistName';
      // Stejné sklo jako všechny ostatní sheety (dřív chybělo -- text ležel
      // přímo přes stránku, živě nahlášeno).
      return GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Charita jménem: $artistName', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Vyber charitu – otevře se její stránka pro dary. Věnování „$dedication“ se '
                'zkopíruje, vlož ho do poznámky k daru (pole "na počest / věnování"). Dar je '
                'oficiálně od tebe, jméno interpreta je v jeho věnování.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final c in _charities)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Symbols.volunteer_activism_rounded),
                  title: Text(c.name),
                  subtitle: Text(c.about),
                  trailing: const Icon(Symbols.open_in_new_rounded),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    // Safari otevře novou kartu jen přímo z klepnutí -- proto
                    // nejdřív odkaz, věnování do schránky až potom.
                    final opened = openExternal(c.url);
                    try {
                      await Clipboard.setData(ClipboardData(text: dedication));
                      showToast(messenger, 'Zkopírováno: $dedication');
                    } catch (_) {}
                    await opened;
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}
