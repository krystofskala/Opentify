import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/toast.dart';
import '../profile/home_genres_sheet.dart';

/// Domů › Upravit: pořadí sekcí (přetažením) a které se ukazují. Ukládá se
/// k profilu (`PUT /home/layout`), platí na všech zařízeních.
Future<void> showHomeLayoutSheet(BuildContext context) =>
    showGlassSheet<void>(context, builder: (_) => const _HomeLayoutSheet());

class _Entry {
  _Entry(this.id, this.title, this.visible);
  final String id;
  final String title;
  bool visible;
}

class _HomeLayoutSheet extends ConsumerStatefulWidget {
  const _HomeLayoutSheet();

  @override
  ConsumerState<_HomeLayoutSheet> createState() => _HomeLayoutSheetState();
}

class _HomeLayoutSheetState extends ConsumerState<_HomeLayoutSheet> {
  List<_Entry>? _entries;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await ref.read(apiClientProvider).getJson('/home/layout');
      if (!mounted) return;
      setState(() {
        _entries = [
          for (final s in (json['sections'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
            _Entry(s['id'] as String, s['title'] as String? ?? '', s['visible'] as bool? ?? true),
        ];
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save({bool reset = false}) async {
    final entries = _entries;
    if (entries == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).putJson(
        '/home/layout',
        body: reset
            ? {'order': <String>[], 'hidden': <String>[]}
            : {
                'order': [for (final e in entries) e.id],
                'hidden': [for (final e in entries) if (!e.visible) e.id],
              },
      );
      ref.invalidate(homeProvider);
      if (mounted) {
        Navigator.of(context).pop();
        showToast(ScaffoldMessenger.maybeOf(context), reset ? 'Domů je zase ve výchozím pořadí' : 'Domů upraveno');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _editGenres() async {
    await showHomeGenresSheet(context);
    if (mounted) {
      setState(() => _entries = null);
      await _load();
    }
  }

  /// Chytré seznamy (Mix na teď, Před rokem, Shazam...) se připínají do
  /// "Tvoje výběry" -- tady jde vrátit odepnutý (jinak se připíná v menu).
  List<Widget> _smartLists(ThemeData theme) {
    final pins = ref.watch(quickPinsProvider).valueOrNull;
    if (pins == null || pins.rails.isEmpty) return const [];
    return [
      const SizedBox(height: AppSpacing.sm),
      Text('Chytré seznamy v Tvých výběrech', style: theme.textTheme.titleSmall),
      const SizedBox(height: AppSpacing.xxs),
      Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          for (final rail in pins.rails)
            FilterChip(
              label: Text(rail.title),
              selected: rail.pinned,
              onSelected: (on) async {
                final repo = ref.read(homeRepositoryProvider);
                try {
                  on ? await repo.pinQuick(rail.id, kind: 'rail') : await repo.unpinQuick(rail.id, kind: 'rail');
                } catch (_) {}
                ref.invalidate(quickPinsProvider);
                ref.invalidate(homeProvider);
              },
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    return GlassSheet(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Upravit Domů', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                'Přetažením změníš pořadí sekcí, vypínačem je skryješ.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_error != null)
                Text('Nepodařilo se: $_error', style: TextStyle(color: theme.colorScheme.error))
              else if (entries == null)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Flexible(
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    itemCount: entries.length,
                    onReorderItem: (from, to) => setState(() => entries.insert(to, entries.removeAt(from))),
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return Material(
                        key: ValueKey(e.id),
                        type: MaterialType.transparency,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(AppSpacing.xs),
                              child: Icon(Symbols.drag_indicator_rounded),
                            ),
                          ),
                          title: Text(
                            e.title,
                            style: e.visible
                                ? null
                                : TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                          ),
                          trailing: Switch(
                            value: e.visible,
                            onChanged: (on) => setState(() => e.visible = on),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              GlassButton(
                label: 'Přidat nebo odebrat žánry…',
                icon: Symbols.category_rounded,
                expand: true,
                onPressed: _saving ? null : _editGenres,
              ),
              ..._smartLists(theme),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Výchozí',
                      expand: true,
                      onPressed: _saving || entries == null ? null : () => _save(reset: true),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    flex: 2,
                    child: GlassButton(
                      label: _saving ? 'Ukládám…' : 'Uložit',
                      style: GlassButtonStyle.prominent,
                      expand: true,
                      onPressed: _saving || entries == null ? null : _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
