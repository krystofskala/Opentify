import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../core/device_token.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/page_location.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/toast.dart';
import '../../theme/shapes.dart';

/// Profil › Profily -- jen pro admina. Založit profil (jméno + přihlašovací
/// jméno; heslo si dotyčný vytvoří sám při prvním přihlášení), vynulovat
/// zapomenuté heslo, přepnout se na profil (třeba nahrát mu Spotify data).
/// Ostatní tuhle sekci nevidí vůbec.
/// Adresa pro ostatní: samostatný Tailscale stroj jen s Opentify
/// (docker-compose `tailscale`), ne celé PC.
const _sharedOrigin = AppConfig.sharedOrigin;

class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({super.key});

  void _snack(BuildContext context, Object e) {
    showToast(ScaffoldMessenger.maybeOf(context), e is ApiException ? (e.detail ?? 'Nepodařilo se.') : 'Nepodařilo se.');
  }

  /// Co poslat novému člověku: adresa, jméno, a že si heslo vytvoří sám.
  Future<void> _showLoginInfo(BuildContext context, String name, String username) async {
    final text = 'Opentify: $_sharedOrigin\n'
        'Přihlašovací jméno: $username\n'
        'Heslo si vytvoříš při prvním přihlášení.';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Přihlášení pro $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pošli mu tohle. Heslo nikdo nezná – vytvoří si ho při prvním přihlášení.'),
            const SizedBox(height: AppSpacing.sm),
            SelectableText(text, style: const TextStyle(fontWeight: FontWeight.w700)),
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
            label: 'Kopírovat',
            icon: Symbols.content_copy_rounded,
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  /// Pozvánka: člověk si přes ni sám vybere přihlašovací jméno a heslo.
  Future<void> _showInvite(BuildContext context, String name, String code) async {
    final link = '$_sharedOrigin/?join=$code';
    final text = 'Pozvánka do Opentify: $link\n'
        'Otevři ji se zapnutým Tailscale a vyber si jméno a heslo. '
        'V Android appce ji vlož na přihlašovací obrazovce (Mám pozvánku od správce).';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Pozvánka pro $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pošli mu tohle. Platí 14 dní a jen jednou – jméno i heslo si vybere sám.'),
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
            label: 'Kopírovat',
            icon: Symbols.content_copy_rounded,
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _newInvite(BuildContext context, WidgetRef ref, ProfileRow p) async {
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/users/${p.id}/invite');
      if (context.mounted) await _showInvite(context, p.name, json['invite'] as String);
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  /// Dialog se jménem (a u úpravy i přihlašovacím jménem); null = zrušeno.
  Future<(String, String)?> _askNames(BuildContext context,
      {required String title,
      String name = '',
      String username = '',
      required String confirm,
      bool withUsername = true}) {
    final nameCtl = TextEditingController(text: name);
    final userCtl = TextEditingController(text: username);
    return showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              autofocus: name.isEmpty,
              decoration: const InputDecoration(labelText: 'Jméno (třeba Táta)'),
            ),
            if (withUsername) const SizedBox(height: AppSpacing.sm),
            if (withUsername)
              TextField(
                controller: userCtl,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Přihlašovací jméno', hintText: 'bez mezer'),
              ),
          ],
        ),
        actions: [
          GlassButton(
            label: 'Zrušit',
            style: GlassButtonStyle.plain,
            compact: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          GlassButton(
            label: confirm,
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () => Navigator.of(context).pop((nameCtl.text.trim(), userCtl.text.trim())),
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final names = await _askNames(context, title: 'Nový profil', confirm: 'Vytvořit', withUsername: false);
    if (names == null || names.$1.isEmpty || !context.mounted) return;
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/users', body: {'name': names.$1});
      ref.invalidate(profilesProvider);
      if (context.mounted) await _showInvite(context, names.$1, json['invite'] as String);
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, ProfileRow p) async {
    final names =
        await _askNames(context, title: 'Upravit profil', name: p.name, username: p.username ?? '', confirm: 'Uložit');
    if (names == null || !context.mounted) return;
    try {
      await ref
          .read(apiClientProvider)
          .patchJson('/auth/users/${p.id}', body: {'name': names.$1, 'username': names.$2});
      ref.invalidate(profilesProvider);
      ref.invalidate(authProvider);
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  Future<void> _resetPassword(BuildContext context, WidgetRef ref, ProfileRow p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Vynulovat heslo – ${p.name}?'),
        content: const Text('Odhlásí se na všech zařízeních. Dostaneš novou pozvánku, přes kterou si nastaví nové heslo.'),
        actions: [
          GlassButton(
            label: 'Zrušit',
            style: GlassButtonStyle.plain,
            compact: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          GlassButton(
            label: 'Vynulovat',
            style: GlassButtonStyle.prominent,
            compact: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final json = await ref.read(apiClientProvider).postJson('/auth/users/${p.id}/reset-password');
      ref.invalidate(profilesProvider);
      // Nové heslo si nastaví jen přes pozvánku (ne kdokoli, kdo zná jméno).
      if (context.mounted) await _showInvite(context, p.name, json['invite'] as String);
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  /// ⋯ u profilu -- stejný skleněný sheet jako ostatní menu (ne vyskakovací).
  void _profileMenu(BuildContext context, WidgetRef ref, ProfileRow p) {
    final actions = <(IconData, String, VoidCallback)>[
      (Symbols.edit_rounded, 'Upravit jméno', () => _edit(context, ref, p)),
      if (p.username == null && p.role != 'admin')
        (Symbols.mail_rounded, 'Nová pozvánka', () => _newInvite(context, ref, p)),
      if (p.username != null && !p.hasPassword && p.role != 'admin')
        (Symbols.key_rounded, 'Údaje k přihlášení', () => _showLoginInfo(context, p.name, p.username!)),
      if (p.hasPassword && p.role != 'admin')
        (Symbols.lock_reset_rounded, 'Vynulovat heslo', () => _resetPassword(context, ref, p)),
    ];
    showGlassSheet<void>(
      context,
      builder: (sheet) => GlassSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                child: Text(p.name, style: Theme.of(sheet).textTheme.titleMedium),
              ),
              for (final (icon, label, onTap) in actions)
                ListTile(
                  dense: true,
                  shape: AppShapes.md,
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    onTap();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _revokeDevice(BuildContext context, WidgetRef ref, DeviceRow d) async {
    try {
      await ref.read(apiClientProvider).deleteJson('/auth/devices/${d.id}');
      ref.invalidate(profilesProvider);
      if (context.mounted) toast(context, '${d.label} odhlášeno');
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  Future<void> _switch(WidgetRef ref, String? userId) async {
    await ref.read(apiClientProvider).postJson('/auth/act-as', body: {'user_id': userId});
    await saveActAs(userId);
    ref.invalidate(realtimeClientProvider); // nativně se stránka nenačte znovu
    reloadPage();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).valueOrNull;
    if (auth?.user?.role != 'admin') return const SizedBox.shrink();
    final theme = Theme.of(context);
    final actingId = auth!.acting?.id ?? auth.user!.id;
    final profiles = ref.watch(profilesProvider).valueOrNull ?? const [];
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Profily', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Jen pro tebe. Nový profil dostane přihlašovací jméno, heslo si vytvoří sám. '
          'Přepni se na profil, když mu chceš něco nastavit nebo nahrát jeho Spotify data.',
          style: muted,
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
                        [
                          if (p.username == null) 'čeká na založení účtu (pozvánka)' else p.username!,
                          if (p.username != null && !p.hasPassword) 'heslo vynulované',
                        ].join(' · '),
                        style: muted,
                      ),
                      for (final d in p.deviceList)
                        Row(
                          children: [
                            Flexible(child: Text('${d.label} · ${_ago(d.lastUsedAt)}', style: muted)),
                            // Ztracený telefon: odhlásit jen tohle zařízení.
                            InkWell(
                              borderRadius: BorderRadius.circular(AppRadii.pill),
                              onTap: () => _revokeDevice(context, ref, d),
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.xs),
                                child: Icon(Symbols.close_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ],
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
                IconButton(
                  tooltip: 'Další možnosti',
                  icon: const Icon(Symbols.more_horiz_rounded),
                  onPressed: () => _profileMenu(context, ref, p),
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
                  ref.invalidate(realtimeClientProvider);
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

/// "před 5 min" / "včera" -- poslední použití zařízení.
String _ago(String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inMinutes < 2) return 'teď';
  if (d.inHours < 1) return 'před ${d.inMinutes} min';
  if (d.inDays < 1) return 'před ${d.inHours} h';
  if (d.inDays == 1) return 'včera';
  return 'před ${d.inDays} dny';
}
