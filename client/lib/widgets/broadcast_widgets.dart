import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/broadcast_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../theme/shapes.dart';
import 'glass/glass.dart';
import 'media_card.dart' show ArtworkImage;

/// Sdílený stream -- UI: list "Vysílat" (volba viditelnosti při každém
/// startu, výchozí jen pozvaní), sekce Domů "Teď streamuje" a lišta
/// posluchače ("Posloucháš s X · Odejít"). Logika: state/broadcast_controller.dart.

Future<void> showBroadcastSheet(BuildContext context) {
  HapticFeedback.selectionClick();
  return showGlassSheet<void>(context, builder: (_) => const _BroadcastSheet());
}

class _BroadcastSheet extends ConsumerStatefulWidget {
  const _BroadcastSheet();

  @override
  ConsumerState<_BroadcastSheet> createState() => _BroadcastSheetState();
}

class _BroadcastSheetState extends ConsumerState<_BroadcastSheet> {
  String _visibility = 'invited';
  final Set<String> _invited = {};
  late final Future<List<({String id, String name})>> _candidates = ref.read(broadcastProvider.notifier).inviteCandidates();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = ref.watch(broadcastProvider);
    final ctrl = ref.read(broadcastProvider.notifier);
    final children = <Widget>[];
    if (b.role == BroadcastRole.broadcasting) {
      children.addAll([
        Text('Vysíláš', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${b.visibility == 'server' ? 'Vidí všichni na serveru' : 'Vidí jen pozvaní'} · '
          '${b.listeners == 0 ? 'zatím nikdo neposlouchá' : 'poslouchá ${b.listeners}'}',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          icon: const Icon(Symbols.stop_circle_rounded),
          label: const Text('Ukončit vysílání'),
          onPressed: () {
            ctrl.stopBroadcast();
            Navigator.of(context).pop();
          },
        ),
      ]);
    } else if (b.role == BroadcastRole.listening) {
      children.addAll([
        Text('Posloucháš s ${b.hostName ?? '…'}', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          icon: const Icon(Symbols.logout_rounded),
          label: Text(b.ended != null ? 'Vrátit se k mému' : 'Odejít'),
          onPressed: () {
            ctrl.leave();
            Navigator.of(context).pop();
          },
        ),
      ]);
    } else {
      final can = ctrl.canBroadcast;
      children.addAll([
        Text('Vysílat – poslouchej se mnou', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.xs),
        Text(
          can
              ? 'Ostatní uslyší totéž co ty, ve stejnou chvíli. Řídíš jen ty; jejich poslech se jim do vkusu nepočítá.'
              : 'Pusť nejdřív hudbu (mluvené slovo a soubory z telefonu se vysílat nedají).',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
        // ignore: deprecated_member_use
        RadioListTile<String>(
          contentPadding: EdgeInsets.zero,
          value: 'invited',
          // ignore: deprecated_member_use
          groupValue: _visibility,
          // ignore: deprecated_member_use
          onChanged: (v) => setState(() => _visibility = v!),
          title: const Text('Jen pozvaní'),
          subtitle: const Text('Vybereš, kdo vysílání uvidí'),
        ),
        // ignore: deprecated_member_use
        RadioListTile<String>(
          contentPadding: EdgeInsets.zero,
          value: 'server',
          // ignore: deprecated_member_use
          groupValue: _visibility,
          // ignore: deprecated_member_use
          onChanged: (v) => setState(() => _visibility = v!),
          title: const Text('Všichni na serveru'),
        ),
        if (_visibility == 'invited')
          FutureBuilder<List<({String id, String name})>>(
            future: _candidates,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(AppSpacing.sm), child: Center(child: CircularProgressIndicator()));
              }
              final list = snap.data ?? const [];
              if (list.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text(
                    'Pozvat jde jen profily, které sdílí, co poslouchají (Profil › Sdílet, co poslouchám).',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                );
              }
              return Column(
                children: [
                  for (final p in list)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _invited.contains(p.id),
                      title: Text(p.name),
                      onChanged: (on) => setState(() => on == true ? _invited.add(p.id) : _invited.remove(p.id)),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: AppSpacing.sm),
        FilledButton.icon(
          icon: const Icon(Symbols.podcasts_rounded),
          label: const Text('Začít vysílat'),
          onPressed: !can || (_visibility == 'invited' && _invited.isEmpty)
              ? null
              : () {
                  ctrl.startBroadcast(visibility: _visibility, invited: _invited.toList());
                  Navigator.of(context).pop();
                },
        ),
      ]);
    }
    return GlassSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

/// Řádek v Přehrávač › Více: stav vysílání / poslechu, otevře list.
class BroadcastMoreTile extends ConsumerWidget {
  const BroadcastMoreTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(broadcastProvider);
    final (title, subtitle) = switch (b.role) {
      BroadcastRole.broadcasting => ('Vysíláš', b.listeners == 0 ? 'Zatím nikdo neposlouchá' : 'Poslouchá ${b.listeners}'),
      BroadcastRole.listening => ('Posloucháš s ${b.hostName ?? '…'}', 'Odejít a vrátit se k vlastní hudbě'),
      BroadcastRole.none => ('Vysílat', 'Poslouchej se mnou – ostatní uslyší totéž co ty'),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(b.role == BroadcastRole.none ? Symbols.podcasts_rounded : Symbols.sensors_rounded),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () {
        final host = Navigator.of(context).context;
        Navigator.of(context).pop();
        showBroadcastSheet(host);
      },
    );
  }
}

/// Lišta posluchače na Domů: s kým poslouchám, Odejít / Vrátit se k mému.
/// Ukáže se jen při poslechu cizího vysílání.
class BroadcastListeningBanner extends ConsumerWidget {
  const BroadcastListeningBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(broadcastProvider);
    if (b.role != BroadcastRole.listening) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = AppShapes.of(Expressive.cornerMedium);
    final line = b.ended != null
        ? 'Vysílání skončilo'
        : b.waiting
            ? 'Připojuji…'
            : b.weakSync
                ? 'Slabé spojení – dorovnávám'
                : 'Hraje totéž, ve stejnou chvíli';
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: scheme.primaryContainer.withValues(alpha: 0.8)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Row(
            children: [
              Icon(Symbols.sensors_rounded, color: scheme.onPrimaryContainer),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Posloucháš s ${b.hostName ?? '…'}',
                        style: theme.textTheme.titleSmall?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
                    Text(line, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer)),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => ref.read(broadcastProvider.notifier).leave(),
                child: Text(b.ended != null ? 'Vrátit se k mému' : 'Odejít'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sekce Domů "Teď streamuje" (volitelná, výchozí vypnutá): živá vysílání,
/// která smím vidět, s "Připojit". Prázdná = nic se neukáže.
class NowStreamingSection extends ConsumerStatefulWidget {
  const NowStreamingSection({super.key, required this.title});

  final String title;

  @override
  ConsumerState<NowStreamingSection> createState() => _NowStreamingSectionState();
}

class _NowStreamingSectionState extends ConsumerState<NowStreamingSection> {
  @override
  void initState() {
    super.initState();
    // Seznam chodí živě přes WS (`broadcasts.update`); napoprvé i přes HTTP.
    Future.microtask(() => ref.read(broadcastProvider.notifier).refreshList());
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(broadcastProvider);
    final live = b.live.where((l) => !l.mine).toList();
    if (live.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = AppShapes.of(Expressive.cornerMedium);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          for (final l in live)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: DecoratedBox(
                decoration: ShapeDecoration(shape: shape, color: scheme.secondaryContainer.withValues(alpha: 0.72)),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(width: 48, height: 48, child: ArtworkImage(url: l.artworkUrl, iconSize: 24)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${l.name} ${l.isPlaying ? 'streamuje' : 'má pauzu'}',
                                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer)),
                            Text(
                              [l.title ?? '…', if (l.artist != null) l.artist!].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700),
                            ),
                            if (l.listeners > 0)
                              Text('Poslouchá ${l.listeners}', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSecondaryContainer)),
                          ],
                        ),
                      ),
                      if (b.role == BroadcastRole.listening && b.sid == l.id)
                        TextButton(onPressed: () => ref.read(broadcastProvider.notifier).leave(), child: const Text('Odejít'))
                      else
                        FilledButton.tonal(
                          // Přímo z klepnutí -- web smí spustit zvuk jen po gestu.
                          onPressed: () => ref.read(broadcastProvider.notifier).join(l),
                          child: const Text('Připojit'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
