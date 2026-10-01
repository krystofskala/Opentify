import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../core/device_token.dart';

import '../../core/api_client.dart';
import '../../core/page_location.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';

/// Profil › Profily -- jen pro admina. Založit profil (pozvánkový odkaz),
/// přepnout se na něj (třeba nahrát mu Spotify data), zpět na sebe.
/// Běžnému používání se nepřekáží: ostatní tuhle sekci nevidí vůbec.
class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({super.key});

  Future<void> _showInvite(BuildContext context, String name, String code, {bool signup = false}) async {
    final link = inviteLink(code);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(signup ? 'Odkaz pro nové profily' : 'Pozvánka pro $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              signup
                  ? 'Jeden odkaz pro všechny: kdo ho otevře (přes Tailscale), založí si vlastní profil '
                      'pojmenovaný podle Tailscale a jeho další zařízení se pak poznají sama. '
                      'Nový odkaz zruší ten starý.'
                  : 'Pošli odkaz a otevřete ho jednou na jeho zařízení (v Safari, pak Přidat na plochu). '
                      'Platí 14 dní a jen jednou.',
            ),
            const SizedBox(height: AppSpacing.sm),
            SelectableText(link, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          GlassButton(
            label: 'Zavřít',
            style: GlassButtonStyle.plain,
            compact: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          GlassButton(
            label: 'Kopírovat odkaz',
            icon: Symbols.content_copy_rounded,
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nový profil'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Jméno (třeba Táta)'),
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
            label: 'Vytvořit',
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/users', body: {'name': name});
      ref.invalidate(profilesProvider);
      if (context.mounted) await _showInvite(context, name, json['invite'] as String);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e is ApiException ? (e.detail ?? 'Nepodařilo se.') : 'Nepodařilo se.')),
        );
      }
    }
  }

  Future<void> _invite(BuildContext context, WidgetRef ref, ProfileRow p) async {
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/users/${p.id}/invite');
      if (context.mounted) await _showInvite(context, p.name, json['invite'] as String);
    } catch (_) {}
  }

  Future<void> _switch(WidgetRef ref, String? userId) async {
    await ref.read(apiClientProvider).postJson('/auth/act-as', body: {'user_id': userId});
    await saveActAs(userId);
    reloadPage();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).valueOrNull;
    if (auth?.user?.role != 'admin') return const SizedBox.shrink();
    final theme = Theme.of(context);
    final actingId = auth!.acting?.id ?? auth.user!.id;
    final profiles = ref.watch(profilesProvider).valueOrNull ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Profily', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Jen pro tebe. Přepni se na profil, když mu chceš něco nastavit nebo nahrát jeho Spotify data.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final p in profiles)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  p.role == 'admin' ? Symbols.shield_person_rounded : Symbols.person_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.role == 'admin' ? '${p.name} (ty)' : p.name, style: theme.textTheme.bodyLarge),
                      Text(
                        p.devices == 0 ? 'Zatím žádné zařízení' : 'Zařízení: ${p.devices}',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (p.id == actingId)
                  Text('aktivní', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary))
                else
                  GlassButton(
                    label: 'Přepnout',
                    compact: true,
                    onPressed: () => _switch(ref, p.role == 'admin' ? null : p.id),
                  ),
                if (p.role != 'admin')
                  IconButton(
                    tooltip: 'Nová pozvánka',
                    icon: const Icon(Symbols.link_rounded),
                    onPressed: () => _invite(context, ref, p),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: GlassButton(
            label: 'Nový profil',
            icon: Symbols.person_add_rounded,
            compact: true,
            onPressed: () => _create(context, ref),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: GlassButton(
            label: 'Odkaz pro nové profily',
            icon: Symbols.link_rounded,
            compact: true,
            onPressed: () async {
              try {
                final json = await ref.read(apiClientProvider).postJson('/auth/signup-link');
                if (context.mounted) await _showInvite(context, '', json['invite'] as String, signup: true);
              } catch (_) {}
            },
          ),
        ),
      ],
    );
  }
}

/// Pruh nahoře v Profilu, když admin jedná za jiný profil.
class ActingAsBanner extends ConsumerWidget {
  const ActingAsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).valueOrNull;
    final acting = auth?.acting;
    if (auth?.user == null || acting == null || acting.id == auth!.user!.id) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: const StadiumBorder(), color: scheme.primaryContainer),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            children: [
              Icon(Symbols.person_rounded, color: scheme.onPrimaryContainer, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Prohlížíš profil: ${acting.name}', style: TextStyle(color: scheme.onPrimaryContainer)),
              ),
              GlassButton(
                label: 'Zpět na můj',
                compact: true,
                onPressed: () async {
                  await ref.read(apiClientProvider).postJson('/auth/act-as', body: {'user_id': null});
                  await saveActAs(null);
                  reloadPage();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
