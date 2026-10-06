import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/diagnostics.dart' show diagReport;
import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/audio_player_controller.dart';
import '../../state/library_scope.dart';
import '../../state/offline_controller.dart';
import '../../state/provisioning_controller.dart';
import '../../state/providers.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/track_actions.dart' show nowPlayingInfoFor;

/// Test přehrávání přímo v telefonu (Profil, jen admin): appka sama pouští
/// skladby jako uživatel -- klepnutí, Další, přetočení, plynulý přechod,
/// soubor v telefonu, nestažená skladba -- a měří, za jak dlouho začnou
/// hrát. Výsledky odejdou na server (`playback-test` v client-log). Nic se
/// nezapočítá do poslechů (`AudioPlayerController.testMode`).
class PlaybackTestScreen extends ConsumerStatefulWidget {
  const PlaybackTestScreen({super.key});

  @override
  ConsumerState<PlaybackTestScreen> createState() => _PlaybackTestScreenState();
}

class _Step {
  _Step(this.label, this.title, this.source);
  final String label;
  final String title;
  final String source;
  int? ms;
  String? error;
  String? lifecycle;

  bool get ok => ms != null && error == null;

  Map<String, Object?> toJson() =>
      {'step': label, 'title': title, 'source': source, 'ms': ms, 'error': error, 'app': lifecycle};
}

class _PlaybackTestScreenState extends ConsumerState<PlaybackTestScreen> {
  final List<_Step> _steps = [];
  bool _running = false;
  bool _cancel = false;
  String? _status;

  AudioPlayerController get _player => ref.read(audioPlayerControllerProvider.notifier);
  AudioPlayerState get _state => ref.read(audioPlayerControllerProvider);

  @override
  void dispose() {
    _cancel = true;
    if (_running) _player.testMode = false;
    super.dispose();
  }

  String _sourceOf(String id) {
    if (ref.read(offlineControllerProvider.notifier).has(id)) return 'telefon';
    final p = ref.read(provisioningControllerProvider)[id];
    return p?.status == 'AVAILABLE' ? 'server' : 'nestažená';
  }

  /// Spustí `action` a čeká, až skladba `id` opravdu hraje (pozice běží).
  Future<_Step> _measure(
    String label,
    NowPlayingInfo info,
    void Function() action, {
    Duration timeout = const Duration(seconds: 30),
    Duration? from,
    String? source,
  }) async {
    final step = _Step(label, '${info.artistName ?? ''} – ${info.title}', source ?? _sourceOf(info.recordingId));
    setState(() => _steps.add(step));
    final watch = Stopwatch()..start();
    action();
    Duration? base = from;
    while (!_cancel) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final s = _state;
      if (s.nowPlaying?.recordingId != info.recordingId) {
        if (watch.elapsed > timeout) break;
        continue;
      }
      if (s.error != null) {
        step.error = s.error;
        break;
      }
      base ??= s.isPlaying && !s.isBuffering ? s.position : null;
      if (base != null && s.isPlaying && s.position - base >= const Duration(milliseconds: 300)) {
        // Pozice se hlásí po ~200 ms -- odečíst, co už odehrálo.
        step.ms = max(0, watch.elapsedMilliseconds - (s.position - base).inMilliseconds);
        break;
      }
      if (watch.elapsed > timeout) {
        step.error = 'nezačalo hrát do ${timeout.inSeconds} s';
        break;
      }
    }
    step.lifecycle = WidgetsBinding.instance.lifecycleState?.name;
    if (mounted) setState(() {});
    return step;
  }

  Future<void> _listen(Duration d) async {
    final end = DateTime.now().add(d);
    while (!_cancel && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _cancel = false;
      _steps.clear();
      _status = 'Načítám skladby…';
    });
    _player.testMode = true;
    try {
      final repo = ref.read(libraryRepositoryProvider);
      final library = (await repo.localTracks(limit: 300)).items.map(nowPlayingInfoFor).toList()..shuffle();
      if (library.length < 14) {
        setState(() => _status = 'V knihovně je málo stažených skladeb.');
        return;
      }

      // 1) Klepnutí na staženou skladbu.
      setState(() => _status = 'Klepnutí na staženou skladbu');
      for (final info in library.take(5)) {
        if (_cancel) return;
        await _measure('klepnutí', info, () => _player.playQueue([info], 0, sourceLabel: 'Test', rememberProgress: false));
        await _listen(const Duration(seconds: 3));
      }

      // 2) Další ve frontě (a předstahování).
      setState(() => _status = 'Tlačítko Další');
      final queue = library.skip(5).take(9).toList();
      await _measure('fronta', queue[0], () => _player.playQueue(queue, 0, sourceLabel: 'Test', rememberProgress: false));
      for (var i = 1; i <= 5 && !_cancel; i++) {
        await _listen(const Duration(seconds: 3));
        await _measure('další', queue[i], () => _player.next());
      }

      // 3) Přetočení doprostřed.
      setState(() => _status = 'Přetočení');
      for (var i = 0; i < 2 && !_cancel; i++) {
        final s = _state;
        final total = s.duration;
        if (s.nowPlaying == null || total == null) break;
        final target = total * 0.5 + Duration(seconds: i * 10);
        await _measure('přetočení', s.nowPlaying!, () => _player.seek(target), from: target, source: 'stejná');
        await _listen(const Duration(seconds: 2));
      }

      // 4) Plynulý přechod na další skladbu (konec skladby).
      setState(() => _status = 'Přechod na další skladbu');
      for (var i = 0; i < 2 && !_cancel; i++) {
        final s = _state;
        final total = s.duration;
        final idx = s.queueIndex;
        if (total == null || idx + 1 >= s.queue.length) break;
        final nextInfo = s.queue[idx + 1];
        await _player.seek(total - const Duration(seconds: 5));
        // Měří se od konce skladby (5 s), ne od přetočení.
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!_cancel && _state.nowPlaying?.recordingId != nextInfo.recordingId) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (DateTime.now().isAfter(deadline)) break;
        }
        await _measure('přechod', nextInfo, () {}, source: 'konec skladby');
        await _listen(const Duration(seconds: 2));
      }

      // 5) Soubor uložený v telefonu.
      final offline = ref.read(offlineControllerProvider).tracks.values.where((t) => !t.id.startsWith('pc:')).toList()
        ..shuffle();
      if (offline.isNotEmpty) setState(() => _status = 'Skladba v telefonu');
      for (final t in offline.take(2)) {
        if (_cancel) return;
        final info = NowPlayingInfo(
            recordingId: t.id, title: t.title, artistName: t.artist, releaseId: t.releaseId, artworkUrl: t.artworkUrl);
        await _measure('telefon', info, () => _player.playQueue([info], 0, sourceLabel: 'Test', rememberProgress: false));
        await _listen(const Duration(seconds: 3));
      }

      // 6) Nestažená skladba (oblíbená, která ještě není na serveru).
      setState(() => _status = 'Nestažená skladba');
      final have = await ref.read(libraryIdsProvider.future);
      final liked = (await repo.likedSongs()).items.where((r) => !have.contains(r.id)).toList()..shuffle();
      for (final r in liked.take(2)) {
        if (_cancel) return;
        final info = nowPlayingInfoFor(r);
        await _measure('nestažená', info, () => _player.playQueue([info], 0, sourceLabel: 'Test', rememberProgress: false),
            timeout: const Duration(seconds: 90));
        await _listen(const Duration(seconds: 3));
      }
    } catch (e) {
      _status = 'Test spadl: $e';
    } finally {
      _player.testMode = false;
      if (_state.isPlaying) unawaited(_player.togglePlayPause());
      final failed = _steps.where((s) => !s.ok).length;
      if (_steps.isNotEmpty) {
        diagReport('playback-test', jsonEncode({'failed': failed, 'steps': [for (final s in _steps) s.toJson()]}));
      }
      if (mounted) {
        setState(() {
          _running = false;
          if (_status == null || !_status!.startsWith('Test spadl')) {
            _status = _cancel ? 'Zastaveno · výsledky odeslány' : 'Hotovo · výsledky odeslány';
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final done = [for (final s in _steps) if (s.ms != null) s.ms!]..sort();
    final median = done.isEmpty ? null : done[done.length ~/ 2];
    return Scaffold(
      appBar: const SectionAppBar('Test přehrávání'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.lg + navBottomInset(context)),
        children: [
          Text(
            'Appka sama pustí asi 20 skladeb: klepnutím, tlačítkem Další, přetočením, na konci skladby, '
            'ze souboru v telefonu i nestaženou. Měří, za jak dlouho začnou hrát, a výsledek pošle na server. '
            'Do poslechů se nic nepočítá. Během testu můžeš zamknout telefon nebo přepnout na mobilní data. '
            'Hraje to nahlas.',
            style: muted,
          ),
          const SizedBox(height: AppSpacing.md),
          GlassButton(
            label: _running ? 'Zastavit' : 'Spustit test',
            icon: _running ? Symbols.stop_rounded : Symbols.play_arrow_rounded,
            style: GlassButtonStyle.prominent,
            expand: true,
            onPressed: _running ? () => setState(() => _cancel = true) : _run,
          ),
          if (_status != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_status!, style: theme.textTheme.titleSmall),
          ],
          if (median != null)
            Text('Medián startu ${(median / 1000).toStringAsFixed(1)} s · '
                '${_steps.where((s) => !s.ok && s.ms == null && s.error != null).length} selhání', style: muted),
          const SizedBox(height: AppSpacing.sm),
          for (final s in _steps)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                s.error != null
                    ? Symbols.error_rounded
                    : s.ms == null
                        ? Symbols.hourglass_top_rounded
                        : Symbols.check_circle_rounded,
                color: s.error != null ? theme.colorScheme.error : null,
              ),
              title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${s.label} · ${s.source}${s.error != null ? ' · ${s.error}' : ''}',
                  style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: s.ms == null ? null : Text('${(s.ms! / 1000).toStringAsFixed(1)} s'),
            ),
        ],
      ),
    );
  }
}
