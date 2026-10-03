import '../../routing/branches.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart';
import '../../core/cz_plural.dart';
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/artwork_provider.dart';
import '../../state/audio_player_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/net_image.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';
import '../../widgets/toast.dart';

/// Jedna podezřelá skladba z kontroly Shazamem.
class VerifyItem {
  VerifyItem.fromJson(Map<String, dynamic> j)
      : recordingId = j['recordingId'] as String,
        title = j['title'] as String? ?? '',
        artist = j['artist'] as String? ?? '',
        album = j['album'] as String?,
        releaseId = j['releaseId'] as String?,
        artistId = j['artistId'] as String?,
        verdict = j['verdict'] as String? ?? 'mismatch',
        gotTitle = j['gotTitle'] as String?,
        gotArtist = j['gotArtist'] as String?,
        expectedMs = j['expectedMs'] as int?,
        actualMs = j['actualMs'] as int?,
        ownFile = j['ownFile'] as bool? ?? false,
        review = j['review'] as String?;

  final String recordingId;
  final String title;
  final String artist;
  final String? album;
  final String? releaseId;
  final String? artistId;
  final String verdict;
  final String? gotTitle;
  final String? gotArtist;
  final int? expectedMs;
  final int? actualMs;
  final bool ownFile;
  final String? review;
}

String _mmss(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

final verifyReportProvider = FutureProvider.autoDispose<List<VerifyItem>>((ref) async {
  final json = await ref.watch(apiClientProvider).getJson('/library/verify-report');
  return [for (final j in (json['items'] as List<dynamic>).cast<Map<String, dynamic>>()) VerifyItem.fromJson(j)];
});

/// Profil › Kontrola stažených: skladby, u kterých Shazam slyší něco jiného
/// (nebo soubor nejde přečíst). Pustit, posoudit, "Je to v pořádku" nebo
/// "Stáhnout znovu" -- nic se nemění bez klepnutí.
class VerifyDownloadsScreen extends ConsumerStatefulWidget {
  const VerifyDownloadsScreen({super.key});

  @override
  ConsumerState<VerifyDownloadsScreen> createState() => _VerifyDownloadsScreenState();
}

class _VerifyDownloadsScreenState extends ConsumerState<VerifyDownloadsScreen> {
  final Set<String> _done = {};
  final Map<String, String> _state = {}; // recordingId -> 'ok' | 'redownload'

  Future<void> _act(VerifyItem item, String action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(apiClientProvider).postJson('/library/verify-report/${item.recordingId}/$action');
      setState(() {
        _state[item.recordingId] = action;
        if (action == 'ok' || action == 'relabel') _done.add(item.recordingId);
      });
    } catch (e) {
      final detail = e is ApiException ? e.detail : null;
      showToast(messenger, detail ?? 'Nepodařilo se.');
    }
  }

  void _play(VerifyItem item) {
    ref.read(audioPlayerControllerProvider.notifier).playTrack(
          NowPlayingInfo(
            recordingId: item.recordingId,
            title: item.title,
            artistName: item.artist,
            artistId: item.artistId,
            releaseId: item.releaseId,
          ),
          sourceLabel: 'Kontrola stažených',
        );
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(verifyReportProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const SectionAppBar('Kontrola stažených'),
      bottomNavigationBar: const ShellBarSpace(),
      body: report.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Přehled se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(verifyReportProvider),
        ),
        data: (all) {
          final items = [
            for (final i in all)
              if (!_done.contains(i.recordingId)) i
          ];
          if (items.isEmpty) {
            return const EmptyState(
              icon: Symbols.task_alt_rounded,
              message: 'Všechno prošlé. Nové podezřelé skladby se objeví po další kontrole.',
            );
          }
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 32 + navBottomInset(context)),
            itemCount: items.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    '${songsCount(items.length)} k projití. Shazam u nich slyší jinou skladbu, délka souboru '
                    'nesedí, nebo soubor nejde přečíst. Pusť si ji a rozhodni: je to dobře, nebo má Shazam pravdu – pak se skladba '
                    'stáhne znovu z jiného výsledku. Kontrast '
                    'a tvoje vlastní hudba zůstávají beze změny.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                );
              }
              final item = items[index - 1];
              return _VerifyRow(
                item: item,
                state: _state[item.recordingId] ?? item.review,
                onPlay: () => _play(item),
                onOk: () => _act(item, 'ok'),
                // Vlastní hudba: soubor je dobrý, jen špatně přiřazený -> přeřadit
                // ke skladbě, kterou slyší Shazam. Stažená: stáhnout znovu.
                onRedownload: item.ownFile
                    ? (item.gotTitle == null ? null : () => _act(item, 'relabel'))
                    : () => _act(item, 'redownload'),
              );
            },
          );
        },
      ),
    );
  }
}

class _VerifyRow extends ConsumerWidget {
  const _VerifyRow({
    required this.item,
    required this.state,
    required this.onPlay,
    required this.onOk,
    required this.onRedownload,
  });

  final VerifyItem item;
  final String? state;
  final VoidCallback onPlay;
  final VoidCallback onOk;
  final VoidCallback? onRedownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final art =
        ref.watch(recordingArtworkProvider((releaseId: item.releaseId, artistId: item.artistId))).valueOrNull;
    final lengths = item.expectedMs != null && item.actualMs != null
        ? 'soubor ${_mmss(item.actualMs!)}, má být ${_mmss(item.expectedMs!)}'
        : null;
    final heard = switch (item.verdict) {
      'broken' => 'Soubor nejde přečíst',
      'suspect' => 'Délka nesedí ($lengths), Shazam nepoznal',
      _ => 'Shazam slyší: ${item.gotTitle ?? '?'} – ${item.gotArtist ?? '?'}${lengths != null ? ' · $lengths' : ''}',
    };
    final redownloading = state == 'redownload';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onPlay,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: SizedBox.square(
                dimension: 56,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (art != null) NetImage(url: art) else ColoredBox(color: theme.colorScheme.surfaceContainerHigh),
                    const Center(child: Icon(Symbols.play_arrow_rounded, color: Colors.white, fill: 1)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  [item.artist, if (item.album != null) item.album].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(heard, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary)),
                const SizedBox(height: AppSpacing.xs),
                if (redownloading)
                  Text(
                    'Stahuje se znovu – po další kontrole se ukáže, jestli sedí.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  )
                else
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      // Dvě jasné volby: soubor sedí, nebo Shazam má pravdu (= špatný soubor).
                      GlassButton(label: 'Je to dobře', icon: Symbols.graphic_eq_rounded, compact: true, onPressed: onOk),
                      if (onRedownload != null)
                        GlassButton(
                          label: 'Shazam má pravdu',
                          icon: Symbols.graphic_eq_rounded,
                          compact: true,
                          onPressed: onRedownload,
                        ),
                      if (item.ownFile)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Vlastní hudba – soubor zůstane, jen se přeřadí',
                            style: theme.textTheme.bodySmall?.copyWith(color: muted),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
