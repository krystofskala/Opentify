import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/audio_player_controller.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/section_app_bar.dart';
import 'tuner_bridge.dart';
import 'tuner_logic.dart';

enum _Phase { idle, starting, listening, paused, error }

/// Ladička kytary (Profil › Ladička). Mikrofon -> detektor v AudioWorkletu
/// (web/tuner/) -> `TunerFilter` -> ručička. Vše jen v zařízení.
///
/// Mikrofon se otevírá jen z klepnutí (iOS) a zavírá při odchodu i při
/// přepnutí appky do pozadí. Hudba se při spuštění pozastaví -- s otevřeným
/// mikrofonem by ji iOS stejně přepnul do sluchátka (viz
/// docs/GUITAR_TUNER_RESEARCH.md).
class TunerScreen extends ConsumerStatefulWidget {
  const TunerScreen({super.key});

  @override
  ConsumerState<TunerScreen> createState() => _TunerScreenState();
}

class _TunerScreenState extends ConsumerState<TunerScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _prefTuning = 'tuner.tuning.v1';
  static const _prefA4 = 'tuner.a4.v1';

  final _filter = TunerFilter(tuning: guitarTunings.first);
  final _out = ValueNotifier<TunerOutput>(TunerOutput.idle);
  final _needle = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_onTick);
  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastTick = Duration.zero;

  _Phase _phase = _Phase.idle;
  TunerStartException? _error;
  bool _micUsed = false;
  late final AudioPlayerController _player = ref.read(audioPlayerControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _player; // načíst hned -- v dispose už se ref použít nesmí
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _filter.tuning = tuningById(prefs.getString(_prefTuning));
        _filter.a4 = prefs.getDouble(_prefA4) ?? 440;
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefTuning, _filter.tuning.id);
      await prefs.setDouble(_prefA4, _filter.a4);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _stopMic();
    _out.dispose();
    _needle.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Na pozadí mikrofon zavřít (PWA ho stejně nesmí držet); zpět jen
    // klepnutím -- iOS mikrofon bez gesta nepustí.
    if (state != AppLifecycleState.resumed && _phase == _Phase.listening) _pause();
  }

  Future<void> _start() async {
    // Bez await -- mikrofon se musí otevřít ještě v rámci klepnutí. I skladba,
    // co se teprve načítá (jinak by se po stažení rozehrála do ladění).
    unawaited(ref.read(audioPlayerControllerProvider.notifier).pauseIfPlaying());
    setState(() {
      _phase = _Phase.starting;
      _error = null;
    });
    _filter.reset();
    _out.value = TunerOutput.idle;
    try {
      await startTuner(
        onData: (hz, clarity, rms) {
          if (!mounted) return;
          _out.value = _filter.add(hz, clarity, rms, _clock.elapsed);
        },
        onState: (state) {
          if (!mounted || _phase != _Phase.listening) return;
          // Hovor, Siri, zamčení... -> kontext se pozastaví.
          if (state == 'suspended' || state == 'interrupted' || state == 'closed') _pause();
        },
      );
      _micUsed = true;
      if (!mounted) return;
      setState(() => _phase = _Phase.listening);
      if (!_ticker.isActive) _ticker.start();
    } on TunerStartException catch (e) {
      _fail(e);
    } catch (e) {
      _fail(TunerStartException('other', '$e'));
    }
  }

  void _fail(TunerStartException e) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _error = e;
    });
  }

  /// Zavřít mikrofon a pak vrátit přehrávač do použitelného stavu.
  void _stopMic() {
    final used = _micUsed;
    _micUsed = false;
    stopTuner().whenComplete(() {
      if (used) _player.recoverAfterMicrophone();
    });
  }

  void _pause() {
    _stopMic();
    _ticker.stop();
    _out.value = TunerOutput.idle;
    if (mounted) setState(() => _phase = _Phase.paused);
  }

  void _onTick(Duration elapsed) {
    // Ručička: kriticky tlumené dojetí k vyhlazené hodnotě filtru, ať se
    // hýbe plynule i mezi odhady detektoru (~47×/s).
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final out = _out.value;
    final target = out.active ? out.cents.clamp(-50.0, 50.0) : 0.0;
    final k = 1 - math.exp(-dt.clamp(0.0, 0.1) / 0.06);
    final next = _needle.value + (target - _needle.value) * k;
    if ((next - _needle.value).abs() > 0.01) _needle.value = next;
  }

  void _selectString(int index) {
    setState(() {
      _filter.targetString = _filter.targetString == index ? null : index;
      _filter.chromatic = false;
      _filter.reset();
    });
    _out.value = TunerOutput.idle;
  }

  void _autoString() {
    setState(() {
      _filter.targetString = null;
      _filter.reset();
    });
    _out.value = TunerOutput.idle;
  }

  void _playTone() {
    final out = _out.value;
    final string = _filter.targetString ?? out.stringIndex;
    final midi = string != null ? _filter.tuning.midi[string] : (out.midi ?? _filter.tuning.midi.first);
    playTunerTone(midiToHz(midi.toDouble(), a4: _filter.a4));
  }

  Future<void> _openSettings() async {
    await showGlassSheet<void>(
      context,
      builder: (context) => _TunerSettingsSheet(
        filter: _filter,
        onChanged: () {
          setState(() => _filter.reset());
          _out.value = TunerOutput.idle;
          _savePrefs();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tuning = _filter.tuning;
    return Scaffold(
      appBar: SectionAppBar(
        'Ladička',
        actions: [
          IconButton(
            tooltip: 'Ladění a kalibrace',
            icon: const Icon(Symbols.tune_rounded),
            onPressed: _openSettings,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.md),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _openSettings,
                    child: Text(
                      _filter.chromatic
                          ? 'Chromaticky · A4 = ${_filter.a4.round()} Hz'
                          : '${tuning.name} · ${tuning.label}${_filter.a4 != 440 ? ' · A4 = ${_filter.a4.round()} Hz' : ''}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  // Tón a stupnice jako jeden celek uprostřed (dřív mezi nimi
                  // na vysokém displeji zela díra).
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: ValueListenableBuilder<TunerOutput>(
                            valueListenable: _out,
                            // Na menším telefonu se střed radši zmenší, než aby přetekl.
                            builder: (context, out, _) => FittedBox(
                              fit: BoxFit.scaleDown,
                              child: _Readout(
                                out: out,
                                phase: _phase,
                                flats: tuning.flats,
                                error: _error,
                                onStart: _start,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        ValueListenableBuilder<double>(
                          valueListenable: _needle,
                          builder: (context, cents, _) => ValueListenableBuilder<TunerOutput>(
                            valueListenable: _out,
                            builder: (context, out, _) =>
                                _CentsMeter(cents: cents, active: out.active, inTune: out.inTune),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (!_filter.chromatic)
                    ValueListenableBuilder<TunerOutput>(
                      valueListenable: _out,
                      builder: (context, out, _) => _StringRow(
                        tuning: tuning,
                        current: out.active ? out.stringIndex : null,
                        target: _filter.targetString,
                        tuned: _filter.tuned,
                        onTap: _selectString,
                      ),
                    ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_filter.chromatic || _filter.targetString == null)
                        Text(
                          _filter.chromatic ? 'Chromatický režim' : 'Struna se pozná sama',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        )
                      else
                        // Ruční struna -> jedním klepnutím zpět na automatiku
                        // (dřív jen opětovným klepnutím na tu samou strunu).
                        GlassButton(
                          label: 'Auto',
                          icon: Symbols.autorenew_rounded,
                          style: GlassButtonStyle.prominent,
                          compact: true,
                          onPressed: _autoString,
                        ),
                      const SizedBox(width: AppSpacing.sm),
                      GlassButton(
                        label: 'Tón',
                        icon: Symbols.volume_up_rounded,
                        style: GlassButtonStyle.tonal,
                        compact: true,
                        onPressed: _playTone,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Symbols.lock_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Zvuk zůstává v tomhle zařízení, nic se neodesílá.',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Velký tón uprostřed: M3 Expressive tvar, který se při naladění
/// přelije z "cookie" do kruhu a zezelená.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.out,
    required this.phase,
    required this.flats,
    required this.error,
    required this.onStart,
  });

  final TunerOutput out;
  final _Phase phase;
  final bool flats;
  final TunerStartException? error;
  final VoidCallback onStart;

  static const _green = Color(0xFF2FBF71);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listening = phase == _Phase.listening;
    final active = listening && out.active;
    final off = active && !out.inTune;
    final color = !active
        ? scheme.surfaceContainerHighest
        : out.inTune
            ? _green
            : Color.lerp(scheme.primaryContainer, const Color(0xFFE8A33D), (out.cents.abs() / 30).clamp(0.0, 1.0))!;
    final onColor =
        active && out.inTune ? Colors.white : (active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant);

    final Widget center;
    if (active && out.midi != null) {
      center = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            noteName(out.midi!, flats: flats),
            style: theme.textTheme.displayLarge?.copyWith(
              fontSize: 92,
              fontWeight: FontWeight.w900,
              height: 1,
              color: onColor,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 2),
            child: Text(
              '${noteOctave(out.midi!)}',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800, color: onColor.withValues(alpha: 0.7)),
            ),
          ),
        ],
      );
    } else {
      center = Icon(
        listening ? Symbols.graphic_eq_rounded : Symbols.mic_rounded,
        size: 64,
        color: onColor,
      );
    }

    final String headline;
    final IconData? hintIcon;
    if (phase == _Phase.error) {
      headline = switch (error?.kind) {
        'denied' => 'Přístup k mikrofonu je zakázaný',
        'unavailable' => 'Mikrofon se nepodařilo otevřít',
        'unsupported' => 'Tenhle prohlížeč ladičku neumí',
        _ => 'Ladičku se nepodařilo spustit',
      };
      hintIcon = Symbols.error_rounded;
    } else if (!listening) {
      headline = phase == _Phase.paused ? 'Ladička je pozastavená' : 'Připraveno';
      hintIcon = null;
    } else if (!active) {
      headline = 'Zahraj strunu';
      hintIcon = null;
    } else if (out.inTune) {
      headline = 'Naladěno';
      hintIcon = Symbols.check_rounded;
    } else if (out.cents > 0) {
      headline = 'Povol';
      hintIcon = Symbols.arrow_downward_rounded;
    } else {
      headline = 'Přitáhni';
      hintIcon = Symbols.arrow_upward_rounded;
    }

    final String? detail = switch (phase) {
      _Phase.error => switch (error?.kind) {
          'denied' =>
            'Povol mikrofon v Nastavení › Safari › Mikrofon (na počítači u zámečku v adresním řádku) a zkus to znovu.',
          'unavailable' => 'Nepoužívá ho jiná aplikace? Zkus to znovu.',
          'unsupported' => 'Chybí přístup k mikrofonu (Web Audio).',
          _ => error?.detail,
        },
      _Phase.idle => 'iPhone se na mikrofon zeptá při každém spuštění appky.',
      _ => null,
    };

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: Motion.state.duration,
          curve: Motion.state,
          builder: (context, c, child) => ExpressiveMorph(
            size: 208,
            color: c ?? color,
            shape: active && out.inTune
                ? const ExpressiveShape.circle()
                : const ExpressiveShape.cookie(lobes: 9, depth: 0.08),
            child: child!,
          ),
          child: center,
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hintIcon != null) ...[
              Icon(hintIcon, size: 26, color: out.inTune && active ? _green : scheme.onSurface),
              const SizedBox(width: 6),
            ],
            Text(
              headline,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 22,
          child: off || (active && out.inTune)
              ? Text(
                  '${out.cents >= 0 ? '+' : '−'}${out.cents.abs().toStringAsFixed(out.cents.abs() < 10 ? 1 : 0)} centů · ${out.hz.toStringAsFixed(2)} Hz',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                )
              : null,
        ),
        if (detail != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        if (!listening) ...[
          const SizedBox(height: AppSpacing.md),
          GlassButton(
            label: switch (phase) {
              _Phase.starting => 'Spouštím…',
              _Phase.paused => 'Pokračovat',
              _Phase.error => 'Zkusit znovu',
              _ => 'Spustit ladičku',
            },
            icon: Symbols.mic_rounded,
            onPressed: phase == _Phase.starting ? null : onStart,
          ),
        ],
      ],
    );
  }
}

/// Stupnice −50…+50 centů, uprostřed roztažená (logaritmicky): okolí
/// nuly má dílek po 1 centu, ať jde ladit opravdu přesně; zelené pásmo
/// ±2 centy, tenká ručička s hrotem.
class _CentsMeter extends StatelessWidget {
  const _CentsMeter({required this.cents, required this.active, required this.inTune});

  final double cents;
  final bool active;
  final bool inTune;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 84,
      width: double.infinity,
      child: CustomPaint(
        painter: _MeterPainter(
          cents: cents,
          active: active,
          inTune: inTune,
          tick: scheme.onSurfaceVariant,
          needle: inTune ? _Readout._green : scheme.onSurface,
          zone: _Readout._green,
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  const _MeterPainter({
    required this.cents,
    required this.active,
    required this.inTune,
    required this.tick,
    required this.needle,
    required this.zone,
  });

  final double cents;
  final bool active;
  final bool inTune;
  final Color tick;
  final Color needle;
  final Color zone;

  /// 0..1 od středu k okraji; 1 cent u nuly ≈ 2,5 % poloviny stupnice.
  static double _warp(double c) {
    const k = 4.0;
    final v = math.log(1 + c.abs() / k) / math.log(1 + 50 / k);
    return c < 0 ? -v : v;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 16.0;
    final half = (size.width - 2 * pad) / 2;
    final cx = size.width / 2;
    final mid = size.height / 2 - 6;
    double x(double c) => cx + _warp(c.clamp(-50.0, 50.0)) * half;

    // Pásmo "naladěno" (±2 centy).
    canvas.drawRRect(
      RRect.fromLTRBR(x(-TunerFilter.inTuneEnter), mid - 22, x(TunerFilter.inTuneEnter), mid + 22,
          const Radius.circular(AppRadii.xxs)),
      Paint()..color = zone.withValues(alpha: inTune ? 0.38 : 0.18),
    );

    final paint = Paint()..strokeCap = StrokeCap.round;
    final ticks = <int>[
      for (var c = -10; c <= 10; c++) c,
      for (final c in const [15, 20, 25, 30, 40, 50]) ...[c, -c],
    ];
    for (final c in ticks) {
      final zero = c == 0;
      final labelled = const {5, 10, 25, 50}.contains(c.abs());
      final len = zero ? 22.0 : (labelled ? 14.0 : (c.abs() <= 10 ? 8.0 : 6.0));
      paint
        ..color = tick.withValues(alpha: zero ? 0.95 : (labelled ? 0.65 : 0.32))
        ..strokeWidth = zero ? 2.4 : (labelled ? 1.6 : 1.1);
      canvas.drawLine(Offset(x(c.toDouble()), mid - len), Offset(x(c.toDouble()), mid + len), paint);
    }
    for (final c in const [-50, -25, -10, -5, 5, 10, 25, 50]) {
      final tp = TextPainter(
        text: TextSpan(
          text: c > 0 ? '+$c' : '−${c.abs()}',
          style: TextStyle(
            color: tick.withValues(alpha: 0.7),
            fontSize: 10.5,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x(c.toDouble()) - tp.width / 2, mid + 25));
    }
    if (!active) return;
    // Ručička: tenká linka (přesně čitelná proti dílkům) s hrotem nahoře.
    final nx = x(cents);
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(nx, mid - 26 + 1.5), Offset(nx, mid + 22 + 1.5), shadow);
    canvas.drawLine(
      Offset(nx, mid - 26),
      Offset(nx, mid + 22),
      Paint()
        ..color = needle
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    final head = Path()
      ..moveTo(nx - 7, mid - 36)
      ..lineTo(nx + 7, mid - 36)
      ..lineTo(nx, mid - 26)
      ..close();
    canvas.drawPath(head, Paint()..color = needle);
  }

  @override
  bool shouldRepaint(covariant _MeterPainter old) =>
      old.cents != cents || old.active != active || old.inTune != inTune || old.needle != needle || old.tick != tick;
}

/// Řada strun (6. vlevo, jako při pohledu na hmatník). Klepnutí = ruční
/// ladění té struny, druhé klepnutí = zpět automaticky.
class _StringRow extends StatelessWidget {
  const _StringRow({
    required this.tuning,
    required this.current,
    required this.target,
    required this.tuned,
    required this.onTap,
  });

  final GuitarTuning tuning;
  final int? current;
  final int? target;
  final Set<int> tuned;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < tuning.midi.length; i++)
          Builder(builder: (context) {
            final isTarget = target == i;
            final isCurrent = current == i;
            final done = tuned.contains(i);
            final bg = isCurrent || isTarget ? scheme.primary : scheme.surfaceContainerHighest;
            final fg = isCurrent || isTarget ? scheme.onPrimary : scheme.onSurface;
            return Semantics(
              button: true,
              selected: isTarget,
              label: '${6 - i}. struna ${noteName(tuning.midi[i], flats: tuning.flats)}',
              child: GestureDetector(
                onTap: () => onTap(i),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedContainer(
                          duration: Motion.state.duration,
                          curve: Motion.state,
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: bg,
                            shape: BoxShape.circle,
                            border: isTarget ? Border.all(color: scheme.onSurface, width: 2.5) : null,
                          ),
                          child: Text(
                            noteName(tuning.midi[i], flats: tuning.flats),
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: fg),
                          ),
                        ),
                        if (done)
                          Positioned(
                            right: -3,
                            top: -3,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: const BoxDecoration(color: _Readout._green, shape: BoxShape.circle),
                              child: const Icon(Symbols.check_rounded, size: 13, color: Colors.white, weight: 700),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${6 - i}',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}

/// Ladění (předvolby), chromatický režim a kalibrace A4.
class _TunerSettingsSheet extends StatefulWidget {
  const _TunerSettingsSheet({required this.filter, required this.onChanged});

  final TunerFilter filter;
  final VoidCallback onChanged;

  @override
  State<_TunerSettingsSheet> createState() => _TunerSettingsSheetState();
}

class _TunerSettingsSheetState extends State<_TunerSettingsSheet> {
  TunerFilter get f => widget.filter;

  void _update(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassSheet(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
          children: [
            Text('Ladění', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpacing.xs),
            for (final t in guitarTunings)
              InkWell(
                borderRadius: BorderRadius.circular(Expressive.cornerMedium),
                onTap: () => _update(() {
                  f.tuning = t;
                  f.chromatic = false;
                  f.targetString = null;
                  f.tuned.clear();
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                            Text(t.label, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      if (!f.chromatic && f.tuning.id == t.id) Icon(Symbols.check_rounded, color: scheme.primary),
                    ],
                  ),
                ),
              ),
            const Divider(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Chromaticky', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      Text(
                        'Ukáže libovolný tón, ne jen struny (ukulele, zpěv, jiné nástroje).',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                GlassSwitch(
                  value: f.chromatic,
                  semanticLabel: 'Chromatický režim',
                  onChanged: (v) => _update(() {
                    f.chromatic = v;
                    f.targetString = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Kalibrace A4', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      Text(
                        'Běžně 440 Hz. Změň jen když ladíš k jinému nástroji.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Níž',
                  icon: const Icon(Symbols.remove_rounded),
                  onPressed: f.a4 <= 430 ? null : () => _update(() => f.a4 -= 1),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    '${f.a4.round()} Hz',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Výš',
                  icon: const Icon(Symbols.add_rounded),
                  onPressed: f.a4 >= 450 ? null : () => _update(() => f.a4 += 1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
