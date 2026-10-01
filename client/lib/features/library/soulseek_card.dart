import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/surface_card.dart';

/// `GET /library/soulseek` (admin) -- co sdílíme a kdo si co stáhl.
final soulseekProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(apiClientProvider).getJson('/library/soulseek'),
);

/// Knihovna › Server: karta „Soulseek" -- sdílené soubory a stažení od nás.
/// Klepnutí ukáže, kdo si co stáhl.
class SoulseekCard extends ConsumerWidget {
  const SoulseekCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(soulseekProvider).valueOrNull;
    if (data == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final downloads = data['downloads'] as int? ?? 0;
    final users = data['users'] as int? ?? 0;
    final files = data['sharedFiles'] as int? ?? 0;
    final connected = data['connected'] as bool? ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: SurfaceCard(
        child: InkWell(
          onTap: () => _showUploads(context, data),
          child: Row(
            children: [
              Icon(Symbols.share_rounded, color: connected ? theme.colorScheme.primary : theme.disabledColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Soulseek', style: theme.textTheme.titleSmall),
                    Text(
                      '${connected ? 'Sdílíš' : 'Odpojeno · sdílíš'} $files souborů · '
                      '${downloads == 0 ? 'zatím si nikdo nic nestáhl' : 'staženo $downloads× ($users lidí)'}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Icon(Symbols.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }

  void _showUploads(BuildContext context, Map<String, dynamic> data) {
    final items = (data['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    showGlassSheet<void>(
      context,
      builder: (context) => GlassSheet(
        child: items.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text('Od tebe si zatím nikdo nic nestáhl.', textAlign: TextAlign.center),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final i in items)
                    ListTile(
                      dense: true,
                      leading: Icon(i['done'] == true ? Symbols.check_circle_rounded : Symbols.schedule_rounded),
                      title: Text(i['file'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${i['user']} · ${i['folder']} · ${_when(i['at'] as String?)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  static String _when(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    return '${t.day}. ${t.month}. ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
}
