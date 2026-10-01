import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';

/// Profil › Domů › "Žánry na Domů": vybrané žánry dostanou na Domů vlastní
/// řadu hned pod Rychlým výběrem (táta: bluegrass, country). Nic vybraného =
/// Domů stejné jako pro všechny -- výběr je dobrovolný.
Future<void> showHomeGenresSheet(BuildContext context) =>
    showGlassSheet<void>(context, builder: (_) => const _HomeGenresSheet());

class _HomeGenresSheet extends ConsumerStatefulWidget {
  const _HomeGenresSheet();

  @override
  ConsumerState<_HomeGenresSheet> createState() => _HomeGenresSheetState();
}

class _HomeGenresSheetState extends ConsumerState<_HomeGenresSheet> {
  List<({String id, String title, Color color})>? _available;
  List<String> _selected = [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await ref.read(apiClientProvider).getJson('/home/genres');
      if (!mounted) return;
      setState(() {
        _available = [
          for (final g in (json['available'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
            (
              id: g['id'] as String,
              title: g['title'] as String? ?? '',
              color: Color(int.parse((g['color'] as String? ?? '#888888').substring(1), radix: 16) | 0xFF000000),
            ),
        ];
        _selected = (json['selected'] as List<dynamic>? ?? const []).cast<String>();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).putJson('/home/genres', body: {'ids': _selected});
      ref.invalidate(homeProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = _available;
    return GlassSheet(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Žánry na Domů', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                'Vybrané žánry dostanou na Domů vlastní řadu. Bez výběru je Domů stejné jako pro ostatní.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_error != null)
                Text('Nepodařilo se: $_error', style: TextStyle(color: theme.colorScheme.error))
              else if (available == null)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (final g in available)
                          FilterChip(
                            label: Text(g.title),
                            selected: _selected.contains(g.id),
                            avatar: _selected.contains(g.id)
                                ? null
                                : Icon(Symbols.circle_rounded, size: 12, fill: 1, color: g.color),
                            onSelected: (on) => setState(() {
                              on ? _selected.add(g.id) : _selected.remove(g.id);
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.md),
              GlassButton(
                label: _saving ? 'Ukládám…' : 'Uložit',
                style: GlassButtonStyle.prominent,
                expand: true,
                onPressed: _saving || available == null ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
