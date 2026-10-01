import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../models/recording_model.dart';
import '../state/audio_player_controller.dart';
import '../state/providers.dart';
import 'glass/glass.dart';
import 'track_actions.dart' show nowPlayingInfoFor;
import 'toast.dart';

bool isYoutubeLink(String text) => RegExp(r'(youtube\.com|youtu\.be)/', caseSensitive: false).hasMatch(text);

/// Odkaz na YouTube: nejdřív zjistit, co to je (název, kanál, videa), pak se
/// zeptat -- skladba, playlist, album interpreta (neoficiální / jen na
/// YouTube), nebo koncert -- a podle toho zařadit (backend
/// app/library/youtube_link.py).
Future<void> importYoutubeLink(BuildContext context, WidgetRef ref, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.of(context);
  final api = ref.read(apiClientProvider);
  showToast(messenger, 'Načítám odkaz z YouTube…', duration: const Duration(minutes: 2));
  Map<String, dynamic> info;
  try {
    info = await api.postJson('/library/import/youtube-inspect', body: {'url': url.trim()});
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    showToast(messenger, e is ApiException ? (e.detail ?? 'Nepodařilo se.') : 'Nepodařilo se.');
    return;
  }
  messenger?.hideCurrentSnackBar();
  if (!context.mounted) return;

  final isPlaylist = info['kind'] == 'playlist';
  final count = (info['videos'] as List<dynamic>? ?? const []).length;
  final choice = await showDialog<({String kind, String artist, String title, int? year})>(
    context: context,
    builder: (context) => _YoutubeKindDialog(
      isPlaylist: isPlaylist,
      title: info['title'] as String? ?? '',
      artist: info['artist'] as String? ?? '',
      channel: info['channel'] as String? ?? '',
      count: count,
    ),
  );
  if (choice == null) return;
  showToast(messenger, 'Přidávám…', duration: const Duration(minutes: 2));
  try {
    final result = await api.postJson('/library/import/youtube', body: {
      'url': url.trim(),
      'kind': choice.kind,
      'artist_name': choice.artist,
      'title': choice.title,
      if (choice.year != null) 'year': choice.year,
    }, timeout: const Duration(minutes: 2));
    messenger?.hideCurrentSnackBar();
    switch (result['kind']) {
      case 'track':
        final json = result['recording'] as Map<String, dynamic>?;
        if (json != null) {
          ref
              .read(audioPlayerControllerProvider.notifier)
              .playTrack(nowPlayingInfoFor(RecordingModel.fromJson(json)), sourceLabel: 'Z YouTube');
        }
      case 'playlist':
        ref.invalidate(myPlaylistsProvider);
        router.push('/playlists/${result['playlistId']}');
      default:
        showToast(messenger, switch (choice.kind) {
            'live' => 'Koncert je u interpreta ${choice.artist}.',
            'soundtrack' => 'Soundtrack „${choice.title}“ je přidaný jako album.',
            _ => 'Album je v diskografii interpreta ${choice.artist}.',
          });
        router.push('/releases/${result['releaseId']}');
    }
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    showToast(messenger, e is ApiException ? (e.detail ?? 'Nepodařilo se.') : 'Nepodařilo se.');
  }
}

class _YoutubeKindDialog extends StatefulWidget {
  const _YoutubeKindDialog({
    required this.isPlaylist,
    required this.title,
    required this.artist,
    required this.channel,
    required this.count,
  });

  final bool isPlaylist;
  final String title;
  final String artist;
  final String channel;
  final int count;

  @override
  State<_YoutubeKindDialog> createState() => _YoutubeKindDialogState();
}

class _YoutubeKindDialogState extends State<_YoutubeKindDialog> {
  late String _kind = widget.isPlaylist ? 'playlist' : 'track';
  late final _artist = TextEditingController(text: widget.artist);
  late final _title = TextEditingController(text: widget.title);
  final _year = TextEditingController();

  @override
  void dispose() {
    _artist.dispose();
    _title.dispose();
    _year.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = [
      if (widget.isPlaylist) ('playlist', 'Playlist', 'Do Knihovny › Sdílené')
      else ('track', 'Skladba', 'Jen ji pustit'),
      ('album', 'Album interpreta', 'Neoficiální / jen na YouTube – do jeho diskografie'),
      ('live', 'Koncert', 'Živé vystoupení – k interpretovi'),
      ('soundtrack', 'Soundtrack', 'Hudba k filmu, seriálu nebo hře – jako album'),
    ];
    final needsNames = _kind == 'album' || _kind == 'live' || _kind == 'soundtrack';
    final soundtrack = _kind == 'soundtrack';
    return AlertDialog(
      title: const Text('Co je tohle?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: theme.textTheme.titleSmall),
            Text(
              [if (widget.channel.isNotEmpty) widget.channel, if (widget.isPlaylist) '${widget.count} videí'].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _kind,
              onChanged: (v) => setState(() => _kind = v ?? _kind),
              child: Column(
                children: [
                  for (final (value, label, hint) in options)
                    RadioListTile<String>(
                      value: value,
                      contentPadding: EdgeInsets.zero,
                      title: Text(label),
                      subtitle: Text(hint),
                    ),
                ],
              ),
            ),
            if (needsNames) ...[
              TextField(
                controller: _artist,
                decoration: InputDecoration(
                  labelText: soundtrack ? 'Skladatel nebo „Various Artists“' : 'Interpret',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _title,
                decoration: InputDecoration(
                  labelText: switch (_kind) {
                    'live' => 'Název koncertu',
                    'soundtrack' => 'Film / seriál / hra',
                    _ => 'Název alba',
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _year,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: const InputDecoration(labelText: 'Rok vydání (nepovinné)', counterText: ''),
              ),
            ],
          ],
        ),
      ),
      actions: [
        GlassButton(
          label: 'Zrušit',
          style: GlassButtonStyle.plain,
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        GlassButton(
          label: 'Přidat',
          style: GlassButtonStyle.prominent,
          compact: true,
          onPressed: () => Navigator.of(context).pop(
            (kind: _kind, artist: _artist.text.trim(), title: _title.text.trim(), year: int.tryParse(_year.text.trim())),
          ),
        ),
      ],
    );
  }
}
