import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../theme/design_tokens.dart';
import 'glass/glass_sheet.dart';
import 'toast.dart';

/// Po spuštění (Android): je-li na GitHubu novější verze, nabídne ji.
/// Jednou za spuštění, tiše bez sítě.
Future<void> offerAppUpdate(BuildContext context) async {
  if (!appUpdatesSupported) return;
  final update = await checkForAppUpdate();
  if (update == null || !context.mounted) return;
  toast(
    context,
    'Nová verze Opentify ${update.version}',
    duration: const Duration(seconds: 10),
    action: SnackBarAction(label: 'Aktualizovat', onPressed: () => showAppUpdateSheet(context, update)),
  );
}

/// Ručně z Profilu: zkontrolovat a případně nabídnout.
Future<void> checkAppUpdateManually(BuildContext context) async {
  final update = await checkForAppUpdate();
  if (!context.mounted) return;
  if (update == null) {
    toast(context, 'Máš nejnovější verzi');
  } else {
    await showAppUpdateSheet(context, update);
  }
}

Future<void> showAppUpdateSheet(BuildContext context, AppUpdate update) =>
    showGlassSheet<void>(context, builder: (_) => GlassSheet(child: _UpdateBody(update: update)));

class _UpdateBody extends StatefulWidget {
  const _UpdateBody({required this.update});

  final AppUpdate update;

  @override
  State<_UpdateBody> createState() => _UpdateBodyState();
}

class _UpdateBodyState extends State<_UpdateBody> {
  double? _progress; // null = ještě nezačalo
  String? _error;

  Future<void> _install() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await installAppUpdate(widget.update, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = 'Stažení se nepovedlo, zkus to znovu.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _progress != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Nová verze ${widget.update.version}', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Stáhne se a Android se zeptá na instalaci. Knihovna, stažené '
            'skladby i nastavení zůstanou.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.md),
          if (busy)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.xxs),
              child: LinearProgressIndicator(value: _progress! > 0 ? _progress : null, minHeight: 6),
            )
          else
            FilledButton(onPressed: _install, child: const Text('Stáhnout a nainstalovat')),
        ],
      ),
    );
  }
}
