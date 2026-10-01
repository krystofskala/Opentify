import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart' show ApiException;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/surface_card.dart';

typedef BlendRow = ({
  String id,
  String partnerName,
  String status,
  bool incoming,
  List<({String id, String title})> playlists,
});

typedef BlendsData = ({List<BlendRow> items, List<({String id, String name})> profiles});

/// `GET /blends` -- moje společné mixy + profily, které můžu pozvat.
final blendsProvider = FutureProvider.autoDispose<BlendsData>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/blends');
  return (
    items: [
      for (final b in (json['items'] as List<dynamic>).cast<Map<String, dynamic>>())
        (
          id: b['id'] as String,
          partnerName: (b['partner'] as Map<String, dynamic>)['name'] as String? ?? '?',
          status: b['status'] as String? ?? 'pending',
          incoming: b['incoming'] as bool? ?? false,
          playlists: [
            for (final p in (b['playlists'] as List<dynamic>).cast<Map<String, dynamic>>())
              (id: p['id'] as String, title: p['title'] as String? ?? ''),
          ],
        ),
    ],
    profiles: [
      for (final p in (json['profiles'] as List<dynamic>).cast<Map<String, dynamic>>())
        (id: p['id'] as String, name: p['name'] as String? ?? ''),
    ],
  );
});

/// Společné mixy (Blend): pozvat profil, přijmout pozvánku, odejít. Mixy
/// vzniknou až po souhlasu obou.
class BlendScreen extends ConsumerWidget {
  const BlendScreen({super.key});

  Future<void> _call(BuildContext context, WidgetRef ref, Future<void> Function() action, String done) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
      ref.invalidate(blendsProvider);
      ref.invalidate(homeProvider);
      messenger?.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(e is ApiException ? (e.detail ?? 'Nepovedlo se.') : 'Nepovedlo se.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(blendsProvider);
    final api = ref.read(apiClientProvider);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Společné mixy')),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Nepodařilo se načíst.')),
        data: (d) => ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text(
              'Společné mixy z poslechů vás obou: Blend, Vaše best of a Nové objevy. '
              'Vzniknou, až pozvánku druhý přijme. Odejít může kdokoli a kdykoli.',
              style: muted,
            ),
            const SizedBox(height: AppSpacing.md),
            for (final b in d.items)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Symbols.join_inner_rounded),
                          const SizedBox(width: 10),
                          Expanded(child: Text('Ty & ${b.partnerName}', style: theme.textTheme.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (b.status == 'active') ...[
                        if (b.playlists.isEmpty)
                          Text('Mixy se připravují – zkus to za chvíli.', style: muted)
                        else
                          for (final p in b.playlists)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Symbols.queue_music_rounded),
                              title: Text(p.title),
                              trailing: const Icon(Symbols.chevron_right_rounded),
                              onTap: () => context.push('/playlists/${p.id}'),
                            ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: GlassButton(
                            label: 'Odejít',
                            style: GlassButtonStyle.plain,
                            compact: true,
                            onPressed: () => _call(context, ref, () => api.deleteJson('/blends/${b.id}'),
                                'Společný mix s ${b.partnerName} zrušen'),
                          ),
                        ),
                      ] else if (b.incoming) ...[
                        Text('${b.partnerName} tě zve do společného mixu.', style: muted),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            GlassButton(
                              label: 'Odmítnout',
                              style: GlassButtonStyle.plain,
                              compact: true,
                              onPressed: () =>
                                  _call(context, ref, () => api.deleteJson('/blends/${b.id}'), 'Pozvánka odmítnuta'),
                            ),
                            const SizedBox(width: 8),
                            GlassButton(
                              label: 'Přijmout',
                              style: GlassButtonStyle.prominent,
                              compact: true,
                              onPressed: () => _call(context, ref, () => api.postJson('/blends/${b.id}/accept'),
                                  'Hotovo – mixy najdeš na Domů'),
                            ),
                          ],
                        ),
                      ] else ...[
                        Text('Čeká, až ${b.partnerName} pozvánku přijme.', style: muted),
                        Align(
                          alignment: Alignment.centerRight,
                          child: GlassButton(
                            label: 'Zrušit pozvánku',
                            style: GlassButtonStyle.plain,
                            compact: true,
                            onPressed: () =>
                                _call(context, ref, () => api.deleteJson('/blends/${b.id}'), 'Pozvánka zrušena'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (d.profiles.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text('Pozvat', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              for (final p in d.profiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Symbols.person_add_rounded),
                  title: Text(p.name),
                  trailing: GlassButton(
                    label: 'Pozvat',
                    compact: true,
                    onPressed: () => _call(context, ref, () => api.postJson('/blends', body: {'partner_id': p.id}),
                        'Pozvánka odeslána – ${p.name} ji uvidí na Domů'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Domů: pozvánka do společného mixu, která čeká na mě.
class BlendInviteBanner extends ConsumerWidget {
  const BlendInviteBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(blendsProvider).valueOrNull?.items.where((b) => b.incoming).toList() ?? const [];
    if (incoming.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final names = incoming.map((b) => b.partnerName).join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: SurfaceCard(
        child: Row(
          children: [
            const Icon(Symbols.join_inner_rounded),
            const SizedBox(width: 10),
            Expanded(child: Text('$names tě zve do společného mixu', style: theme.textTheme.bodyLarge)),
            GlassButton(label: 'Zobrazit', compact: true, onPressed: () => context.push('/blends')),
          ],
        ),
      ),
    );
  }
}
