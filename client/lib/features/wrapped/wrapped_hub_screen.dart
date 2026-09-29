import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/wrapped_repository.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../theme/shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/mix_artwork.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';

/// Rozcestník Wrappedu: dekáda nahoře, pod ní všechny roky. Na rozdíl od
/// Spotify tu zůstávají napořád; rozběhnutý rok a dekáda jsou do Nového
/// roku 2027 zamčené s odpočtem (překvapení).
class WrappedHubScreen extends ConsumerWidget {
  const WrappedHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(wrappedIndexProvider);
    return Scaffold(
      appBar: const SectionAppBar('Wrapped'),
      bottomNavigationBar: const PlayerBar(),
      body: index.when(
        data: (data) => ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xl),
          children: [
            _DecadeCard(period: data.decade, unlockAt: data.unlockAt),
            const SizedBox(height: AppSpacing.lg),
            Text('Tvoje roky', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpacing.sm),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                crossAxisSpacing: AppSpacing.sm,
                mainAxisSpacing: AppSpacing.sm,
              ),
              itemCount: data.years.length,
              itemBuilder: (context, i) => _YearTile(period: data.years[i], unlockAt: data.unlockAt),
            ),
          ],
        ),
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Wrapped se nepodařilo načíst.',
          error: e,
          onRetry: () => ref.invalidate(wrappedIndexProvider),
        ),
      ),
    );
  }
}

class _DecadeCard extends StatelessWidget {
  const _DecadeCard({required this.period, required this.unlockAt});
  final WrappedPeriod period;
  final DateTime unlockAt;

  @override
  Widget build(BuildContext context) {
    final shape = AppShapes.of(Expressive.cornerLarge);
    return GlassPressable(
      shape: shape,
      minSize: Size.zero,
      onPressed: period.locked ? null : () => context.push('/wrapped/decade'),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const MixBackground(style: MixArtStyle.year, hue: 36, seed: 'wrapped:decade'),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Color(0x11000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('TVOJE DEKÁDA', style: _style(13, FontWeight.w800, 0.9)),
                        const Spacer(),
                        if (period.locked) const Icon(Symbols.lock_rounded, color: Colors.white, size: 22),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(period.label, style: _style(44, FontWeight.w900, 1)),
                    const Spacer(),
                    if (period.locked)
                      WrappedCountdown(unlockAt: unlockAt, style: _style(16, FontWeight.w700, 0.95))
                    else
                      Text('Deset let tvojí hudby', style: _style(16, FontWeight.w700, 0.95)),
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

class _YearTile extends StatelessWidget {
  const _YearTile({required this.period, required this.unlockAt});
  final WrappedPeriod period;
  final DateTime unlockAt;

  @override
  Widget build(BuildContext context) {
    final shape = AppShapes.of(Expressive.cornerLarge);
    return GlassPressable(
      shape: shape,
      minSize: Size.zero,
      onPressed: period.locked ? null : () => context.push('/wrapped/${period.id}'),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MixArtwork(
              spec: MixArtSpec(
                style: MixArtStyle.year,
                seed: 'personal:year:${period.id}',
                headline: period.label,
                eyebrow: 'WRAPPED',
              ),
            ),
            if (period.locked)
              ColoredBox(
                color: const Color(0x99000000),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Symbols.lock_rounded, color: Colors.white, size: 28),
                      const SizedBox(height: 6),
                      Text('Od 1. 1. ${unlockAt.toLocal().year}', style: _style(13, FontWeight.w700, 0.95)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

TextStyle _style(double size, FontWeight weight, double opacity) => TextStyle(
      color: Colors.white.withValues(alpha: opacity),
      fontSize: size,
      fontWeight: weight,
      height: 1.05,
      shadows: const [Shadow(blurRadius: 10, color: Colors.black38)],
    );

/// "Odemkne se za 93 dní" -- poslední den hodiny a minuty.
class WrappedCountdown extends StatefulWidget {
  const WrappedCountdown({super.key, required this.unlockAt, required this.style});
  final DateTime unlockAt;
  final TextStyle style;

  @override
  State<WrappedCountdown> createState() => _WrappedCountdownState();
}

class _WrappedCountdownState extends State<WrappedCountdown> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 30), (_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _timer; // spustí odpočet
    final left = widget.unlockAt.difference(DateTime.now());
    final String text;
    if (left.isNegative) {
      text = 'Odemčeno! Otevři znovu.';
    } else if (left.inDays >= 1) {
      final d = left.inDays;
      text = 'Odemkne se za $d ${d == 1 ? 'den' : d <= 4 ? 'dny' : 'dní'}';
    } else {
      text = 'Odemkne se za ${left.inHours} h ${left.inMinutes % 60} min';
    }
    return Text(text, style: widget.style);
  }
}
