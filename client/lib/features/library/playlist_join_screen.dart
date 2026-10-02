import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/section_app_bar.dart';
import '../../widgets/state_views.dart';

/// Odkaz `/playlist-join/<kód>` -- připojí profil ke společnému playlistu a
/// otevře ho.
class PlaylistJoinScreen extends ConsumerStatefulWidget {
  const PlaylistJoinScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<PlaylistJoinScreen> createState() => _PlaylistJoinScreenState();
}

class _PlaylistJoinScreenState extends ConsumerState<PlaylistJoinScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _join();
  }

  Future<void> _join() async {
    try {
      final res = await ref.read(apiClientProvider).postJson('/playlists/join/${widget.code}');
      ref.invalidate(myPlaylistsProvider);
      if (mounted) context.go('/playlists/${res['playlistId']}');
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? (e.detail ?? 'Nepodařilo se.') : 'Nepodařilo se.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const SectionAppBar('Společný playlist'),
        body: _error == null
            ? const LoadingState()
            : EmptyState(icon: Symbols.link_off_rounded, message: _error!),
      );
}
