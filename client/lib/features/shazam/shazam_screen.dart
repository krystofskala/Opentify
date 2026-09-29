import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/listen_later_repository.dart';
import '../../data/recognize_repository.dart';
import '../../state/audio_player_controller.dart';
import '../../state/listen_later_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/net_image.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/track_actions.dart' show nowPlayingInfoFor;
import '../../widgets/track_tile.dart';
import 'open_shazam_badge.dart';
import 'recorder_bridge.dart';

final recognizeRepositoryProvider =
    Provider<RecognizeRepository>((ref) => RecognizeRepository(ref.watch(apiClientProvider)));

enum _Phase { idle, listening, found, notFound, error }

/// Open Shazam (Profil › Open Shazam): poslouchá hudbu kolem, průběžně
/// zkouší rozpoznat (po ~4, 8 a 13 s) a rozpoznanou skladbu uloží do
/// "Poslechnout později" se značkou. Soukromí: viz backend app/recognize.py
/// -- nahrávka jen na vlastní server, Shazamu jen otisk přes VPN.
class ShazamScreen extends ConsumerStatefulWidget {
  const ShazamScreen({super.key});

  @override
  ConsumerState<ShazamScreen> createState() => _ShazamScreenState();
}

class _ShazamScreenState extends ConsumerState<ShazamScreen> with WidgetsBindingObserver {
  static const _attemptsAt = [Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 13)];

  _Phase _phase = _Phase.idle;
  RecognizeResult? _result;
  String? _error;
  int _session = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session++;
    stopRecording();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _phase == _Phase.listening) _cancel();
  }

  void _cancel() {
    _session++;
    stopRecording();
    if (mounted) setState(() => _phase = _Phase.idle);
  }

  Future<void> _listen() async {
    if (_phase == _Phase.listening) return _cancel();
    final session = ++_session;
    final player = ref.read(audioPlayerControllerProvider);
    if (player.isPlaying) ref.read(audioPlayerControllerProvider.notifier).togglePlayPause();
    setState(() {
      _phase = _Phase.listening;
      _result = null;
      _error = null;
    });
    final String mime;
    try {
      mime = await startRecording();
    } on RecorderException catch (e) {
      return _fail(
          session,
          switch (e.kind) {
            'denied' => 'Přístup k mikrofonu je zakázaný. Povol ho v Nastavení › Safari › Mikrofon a zkus to znovu.',
            'unavailable' => 'Mikrofon se nepodařilo otevřít. Nepoužívá ho jiná aplikace?',
            'unsupported' => 'Tenhle prohlížeč nahrávání neumí.',
            _ => 'Nahrávání se nepodařilo spustit.',
          });
    }
    final started = DateTime.now();
    for (final at in _attemptsAt) {
      final wait = at - DateTime.now().difference(started);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (session != _session || !mounted) return;
      try {
        final bytes = await recordingSnapshot();
        if (session != _session || !mounted) return;
        final result = await ref.read(recognizeRepositoryProvider).recognize(bytes, mime);
        if (session != _session || !mounted) return;
        if (result.found) {
          _session++;
          await stopRecording();
          if (!mounted) return;
          ref.read(listenLaterProvider.notifier).refresh();
          setState(() {
            _phase = _Phase.found;
            _result = result;
          });
          return;
        }
      } catch (e) {
        await stopRecording();
        return _fail(session, 'Rozpoznávání teď nejde (${_short(e)}). Zkus to za chvíli.');
      }
    }
    if (session != _session) return;
    await stopRecording();
    if (mounted) setState(() => _phase = _Phase.notFound);
  }

  String _short(Object e) {
    final text = e.toString();
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  void _fail(int session, String message) {
    if (session != _session || !mounted) return;
    _session++;
    setState(() {
      _phase = _Phase.error;
      _error = message;
    });
  }

  void _play(LaterItem item) {
    final track = item.track;
    if (track == null) return;
    ref.read(audioPlayerControllerProvider.notifier).playTrack(
          nowPlayingInfoFor(track, artworkUrl: _result?.coverUrl),
          sourceLabel: 'Open Shazam',
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final later = ref.watch(listenLaterProvider).valueOrNull;
    final recent = [
      ...?later?.active.where((i) => i.fromShazam && i.track != null),
      ...?later?.listened.where((i) => i.fromShazam && i.track != null),
    ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final recentTracks = [for (final i in recent.take(20)) i.track!];

    return Scaffold(
      appBar: const SectionAppBar('Open Shazam'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xl),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: switch (_phase) {
                _Phase.found => _ResultCard(result: _result!, onPlay: _play, onAgain: _listen),
                _ => _ListenButton(
                    phase: _phase,
                    error: _error,
                    onTap: _listen,
                  ),
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Symbols.lock_rounded, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Nahrávka jde jen na tvůj server. Shazamu se přes VPN pošle jen otisk, anonymně.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (recentTracks.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            Text('Nedávno rozpoznané', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpacing.xs),
            for (final track in recentTracks)
              TrackTile(recording: track, queueRecordings: recentTracks, sourceLabel: 'Open Shazam'),
          ],
        ],
      ),
    );
  }
}

/// Velké tlačítko: v klidu "cookie", při poslechu se točí a přelévá mezi
/// tvary (M3 Expressive indikátor), klepnutí poslech zruší.
class _ListenButton extends StatelessWidget {
  const _ListenButton({required this.phase, required this.error, required this.onTap});

  final _Phase phase;
  final String? error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listening = phase == _Phase.listening;
    final (String title, String? detail) = switch (phase) {
      _Phase.listening => ('Poslouchám…', 'Drž telefon blíž k hudbě. Klepnutím zrušíš.'),
      _Phase.notFound => ('Tuhle jsem nepoznal', 'Zkus to blíž k reproduktoru, nebo v refrénu.'),
      _Phase.error => ('Něco se nepovedlo', error),
      _ => ('Klepni a poznej skladbu', 'Rozpoznaná skladba se uloží do Poslechnout později.'),
    };
    return Column(
      children: [
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          button: true,
          label: listening ? 'Zrušit poslech' : 'Poznat skladbu',
          child: GestureDetector(
            onTap: onTap,
            child: SizedBox.square(
              dimension: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (listening)
                    ExpressiveLoadingIndicator(size: 220, color: scheme.primary)
                  else
                    ExpressiveMorph(
                      size: 220,
                      color: scheme.primary,
                      shape: const ExpressiveShape.cookie(lobes: 9, depth: 0.08),
                      child: const SizedBox.shrink(),
                    ),
                  Icon(Symbols.graphic_eq_rounded, size: 84, color: scheme.onPrimary, fill: 1),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(title,
            textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.onPlay, required this.onAgain});

  final RecognizeResult result;
  final void Function(LaterItem item) onPlay;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = result.item;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Symbols.music_note_rounded, size: 72, color: scheme.onSurfaceVariant),
    );
    return Column(
      children: [
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(Expressive.cornerExtraLarge),
          child: SizedBox.square(
            dimension: 220,
            child: result.coverUrl != null ? NetImage(url: result.coverUrl!, placeholder: placeholder) : placeholder,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const OpenShazamBadge(large: true),
        const SizedBox(height: AppSpacing.sm),
        Text(
          result.title ?? '',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(
          [result.artist, result.album].whereType<String>().join(' · '),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Symbols.schedule_rounded, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'Uloženo do Poslechnout později',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (item != null)
              GlassButton(label: 'Přehrát', icon: Symbols.play_arrow_rounded, onPressed: () => onPlay(item)),
            const SizedBox(width: AppSpacing.sm),
            GlassButton(
              label: 'Poznat další',
              icon: Symbols.graphic_eq_rounded,
              style: GlassButtonStyle.tonal,
              onPressed: onAgain,
            ),
          ],
        ),
      ],
    );
  }
}
