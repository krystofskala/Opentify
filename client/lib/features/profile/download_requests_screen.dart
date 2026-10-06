import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';
import '../spoken/spoken_data.dart' show formatSize;

/// Žádosti o stažení (admin): co si kdo chce stáhnout a musím schválit --
/// velké audioknihy, audioknihy z internetu, přes týdenní limit. Stejné
/// rozhodnutí jako tlačítka v upozornění na telefonu; tohle je pro případ,
/// že upozornění propadne. Jen přes Tailscale (správa).
typedef DownloadRequestItem = ({
  String id,
  String who,
  String title,
  int? sizeBytes,
  String reason,
  String status,
  DateTime? createdAt,
});

final downloadRequestsProvider = FutureProvider.autoDispose<List<DownloadRequestItem>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/download-requests');
  return [
    for (final r in (json['requests'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
      (
        id: r['id'] as String,
        who: (r['userName'] as String?) ?? '?',
        title: r['title'] as String? ?? '',
        sizeBytes: (r['sizeBytes'] as num?)?.toInt(),
        reason: r['reason'] as String? ?? '',
        status: r['status'] as String? ?? 'pending',
        createdAt: DateTime.tryParse(r['createdAt'] as String? ?? '')?.toLocal(),
      ),
  ];
});

class DownloadRequestsScreen extends ConsumerWidget {
  const DownloadRequestsScreen({super.key});

  Future<void> _decide(BuildContext context, WidgetRef ref, DownloadRequestItem r, bool approve) async {
    try {
      await ref.read(apiClientProvider).postJson('/download-requests/${r.id}/${approve ? 'approve' : 'deny'}');
      if (context.mounted) toast(context, approve ? 'Povoleno – stahuje se' : 'Zamítnuto');
    } catch (e) {
      if (context.mounted) {
        toast(context, e is ApiException && e.detail != null ? e.detail! : 'Nepodařilo se, zkus to znovu');
      }
    }
    ref.invalidate(downloadRequestsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(downloadRequestsProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: const SectionAppBar('Žádosti o stažení'),
      body: async.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Žádosti se nepodařilo načíst (jen přes Tailscale).',
          error: e,
          onRetry: () => ref.invalidate(downloadRequestsProvider),
        ),
        data: (items) => items.isEmpty
            ? const EmptyState(icon: Symbols.inbox_rounded, message: 'Žádné žádosti o stažení.')
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(downloadRequestsProvider),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
                  children: [
                    for (final r in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.title, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(
                              [
                                r.who,
                                if (r.sizeBytes != null) formatSize(r.sizeBytes),
                                r.reason,
                                if (r.createdAt != null)
                                  '${r.createdAt!.day}. ${r.createdAt!.month}. ${r.createdAt!.hour}:${r.createdAt!.minute.toString().padLeft(2, '0')}',
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: muted,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            if (r.status == 'pending')
                              Wrap(
                                spacing: AppSpacing.xs,
                                children: [
                                  GlassButton(
                                    label: 'Povolit',
                                    icon: Symbols.check_rounded,
                                    style: GlassButtonStyle.prominent,
                                    compact: true,
                                    onPressed: () => _decide(context, ref, r, true),
                                  ),
                                  GlassButton(
                                    label: 'Zamítnout',
                                    icon: Symbols.close_rounded,
                                    style: GlassButtonStyle.plain,
                                    compact: true,
                                    onPressed: () => _decide(context, ref, r, false),
                                  ),
                                ],
                              )
                            else
                              Text(
                                switch (r.status) {
                                  'approved' => '✓ Povoleno',
                                  'denied' => '✕ Zamítnuto',
                                  'expired' => 'Vypršelo',
                                  _ => r.status,
                                },
                                style: muted,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
