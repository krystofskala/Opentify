import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state_views.dart' show humanError;
import '../data/play_now_repository.dart' show PlayNowOptions;
import '../state/auto_continue.dart' show playNowRepositoryProvider;
import 'glass/glass.dart';
import 'toast.dart' show showToast;

/// Objevování v Pusť teď: kolik nového ve várce (Málo = dosavadních ~20 %,
/// Středně ~35 %, Hodně ~50 %). Uloží se hned u profilu -- platí pro další
/// ťuknutí i na ostatních zařízeních.
class DiscoveryPicker extends StatefulWidget {
  const DiscoveryPicker({super.key, required this.initial, required this.onChanged});
  final String initial;
  final Future<void> Function(String level) onChanged;

  @override
  State<DiscoveryPicker> createState() => _DiscoveryPickerState();
}

class _DiscoveryPickerState extends State<DiscoveryPicker> {
  late String _level = widget.initial;

  @override
  Widget build(BuildContext context) {
    return GlassSegmentedControl<String>(
      segments: const [
        GlassSegment(value: 'low', label: 'Málo'),
        GlassSegment(value: 'mid', label: 'Středně'),
        GlassSegment(value: 'high', label: 'Hodně'),
      ],
      selected: _level,
      onChanged: (level) async {
        final before = _level;
        final messenger = ScaffoldMessenger.of(context);
        setState(() => _level = level);
        try {
          await widget.onChanged(level);
        } catch (e) {
          if (!mounted) return;
          setState(() => _level = before);
          showToast(messenger, 'Nepodařilo se uložit: ${humanError(e)}');
        }
      },
    );
  }
}

/// Totéž v Profilu (Moje hudba): načte aktuální úroveň a ukáže přepínač.
class DiscoverySetting extends ConsumerWidget {
  const DiscoverySetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(playNowRepositoryProvider);
    return FutureBuilder<PlayNowOptions>(
      future: repo.options(),
      builder: (context, snap) {
        final options = snap.data;
        if (options == null) return const SizedBox.shrink();
        return DiscoveryPicker(initial: options.discovery, onChanged: repo.setDiscovery);
      },
    );
  }
}
