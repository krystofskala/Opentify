import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api_client.dart';
import '../models/recording_model.dart';
import '../state/providers.dart';
import '../theme/design_tokens.dart';
import 'glass/glass.dart';

String _mmss(int? ms) {
  if (ms == null) return '?';
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "Něco nesedí?" -- Shazam poslechne soubor na serveru (anonymně přes
/// Mullvad) a porovná ho se skladbou. Nic se nemění bez klepnutí.
Future<void> checkTrackWithShazam(BuildContext context, WidgetRef ref, RecordingModel recording) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(const SnackBar(content: Text('Shazam poslouchá…'), duration: Duration(seconds: 3)));
  Map<String, dynamic> result;
  try {
    // Střih + Shazam přes VPN trvá i desítky sekund.
    result = await ref
        .read(apiClientProvider)
        .postJson('/library/verify/${recording.id}', timeout: const Duration(seconds: 90));
  } catch (e) {
    messenger?.showSnackBar(
        SnackBar(content: Text(e is ApiException ? (e.detail ?? 'Kontrola se nepovedla') : 'Kontrola se nepovedla')));
    return;
  }
  if (!context.mounted) return;
  await showGlassSheet<void>(context, builder: (_) => _VerifyResultSheet(recording: recording, result: result));
}

class _VerifyResultSheet extends ConsumerStatefulWidget {
  const _VerifyResultSheet({required this.recording, required this.result});

  final RecordingModel recording;
  final Map<String, dynamic> result;

  @override
  ConsumerState<_VerifyResultSheet> createState() => _VerifyResultSheetState();
}

class _VerifyResultSheetState extends ConsumerState<_VerifyResultSheet> {
  String? _done;

  Future<void> _act(String action) async {
    try {
      await ref.read(apiClientProvider).postJson('/library/verify-report/${widget.recording.id}/$action');
      setState(() => _done = action);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(e is ApiException ? (e.detail ?? 'Nepodařilo se') : 'Nepodařilo se')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final r = widget.result;
    final verdict = r['verdict'] as String?;
    final gotTitle = r['gotTitle'] as String?;
    final gotArtist = r['gotArtist'] as String?;
    final ownFile = r['ownFile'] as bool? ?? false;
    final durationOff = r['durationOff'] as bool? ?? false;

    final (IconData icon, String headline) = switch (verdict) {
      'ok' => (Symbols.check_circle_rounded, 'Sedí – je to ta správná skladba'),
      'mismatch' => (Symbols.error_rounded, 'Shazam slyší něco jiného'),
      'broken' => (Symbols.broken_image_rounded, 'Soubor nejde přečíst'),
      'protected' => (Symbols.shield_rounded, 'Chráněná nahrávka – nekontroluje se'),
      _ => (Symbols.help_rounded, 'Shazam skladbu nepoznal'),
    };

    return GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: verdict == 'ok' ? theme.colorScheme.primary : theme.colorScheme.tertiary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(headline, style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Má být: ${widget.recording.title} – ${widget.recording.artistName ?? '?'}',
                style: theme.textTheme.bodyMedium),
            if (gotTitle != null)
              Text('Shazam slyší: $gotTitle – ${gotArtist ?? '?'}', style: theme.textTheme.bodyMedium),
            Text(
              'Délka souboru ${_mmss(r['actualMs'] as int?)}, v katalogu ${_mmss(r['expectedMs'] as int?)}'
              '${durationOff ? ' – nesedí' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: durationOff ? theme.colorScheme.tertiary : muted),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_done != null)
              Text(
                switch (_done) {
                  'redownload' => 'Stahuje se znovu z jiného výsledku.',
                  'relabel' => 'Soubor přeřazen ke skladbě, kterou slyší Shazam.',
                  _ => 'Označeno jako v pořádku.',
                },
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              )
            else if (verdict != 'ok' && verdict != 'protected')
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  GlassButton(
                      label: 'Je to dobře', icon: Symbols.check_rounded, compact: true, onPressed: () => _act('ok')),
                  if (!ownFile)
                    GlassButton(
                      label: 'Stáhnout znovu',
                      icon: Symbols.refresh_rounded,
                      compact: true,
                      onPressed: () => _act('redownload'),
                    )
                  else if (gotTitle != null)
                    GlassButton(
                      label: 'Shazam má pravdu',
                      icon: Symbols.graphic_eq_rounded,
                      compact: true,
                      onPressed: () => _act('relabel'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
