import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../routing/home_shell.dart' show navBottomInset;
import '../../state/hints.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/section_app_bar.dart';

typedef _Feature = ({IconData icon, String title, String how, Hint? hint});

/// Všechny funkce a gesta na jednom místě (Profil › Co Opentify umí) -- nic
/// nevyskakuje, uživatel si to otevře sám. Texty tipů ze stejného katalogu
/// (`hintTexts`).
const List<(String, List<_Feature>)> _sections = [
  ('Fronta a přehrávání', [
    (icon: Symbols.swipe_right_rounded, title: 'Do fronty tahem', how: '', hint: Hint.queueSwipe),
    (icon: Symbols.schedule_rounded, title: 'Poslechnout později', how: '', hint: Hint.laterSwipe),
    (icon: Symbols.all_inclusive_rounded, title: 'Nekonečné hraní', how: '', hint: Hint.endless),
    (icon: Symbols.queue_music_rounded, title: 'Album nebo playlist do fronty', how: '', hint: Hint.albumQueue),
    (icon: Symbols.repeat_rounded, title: 'A-B opakování', how: '', hint: Hint.abRepeat),
    (icon: Symbols.bedtime_rounded, title: 'Uspávač', how: '', hint: Hint.sleepTimer),
    (
      icon: Symbols.devices_rounded,
      title: 'Hrát na jiném zařízení',
      how: '⋯ v přehrávači › Zařízení – převezmi hudbu na telefonu, počítači nebo tabletu.',
      hint: null,
    ),
  ]),
  ('Vkus a doporučení', [
    (icon: Symbols.heart_broken_rounded, title: 'Nelíbí se mi', how: '', hint: Hint.dislike),
    (
      icon: Symbols.tune_rounded,
      title: 'Víc / míň takových',
      how: '⋯ u skladby › Víc takových / Míň takových – mixy se podle toho upraví.',
      hint: null,
    ),
  ]),
  ('Stahování a knihovna', [
    (icon: Symbols.album_rounded, title: 'Stáhnout celé album', how: '', hint: Hint.albumDownload),
    (
      icon: Symbols.download_for_offline_rounded,
      title: 'Hudba bez internetu',
      how: '⋯ u skladby, alba nebo knihy › Stáhnout do zařízení – hraje i offline.',
      hint: null,
    ),
    (
      icon: Symbols.cloud_upload_rounded,
      title: 'Import ze Spotify, Apple Music, YouTube',
      how: 'Profil › Import – poslechy pro mixy a Wrapped, playlisty a knihovna.',
      hint: null,
    ),
  ]),
  ('Knihy a podcasty', [
    (icon: Symbols.forward_30_rounded, title: '±30 s a rychlost', how: '', hint: Hint.spokenControls),
    (
      icon: Symbols.collections_bookmark_rounded,
      title: 'Sbírky knih',
      how: 'Podrž knihu › Přidat do sbírky – jako playlisty, jen pro knihy.',
      hint: null,
    ),
  ]),
  ('Na počítači', [
    (icon: Symbols.keyboard_rounded, title: 'Klávesy a kolečko', how: '', hint: Hint.desktopKeys),
    (icon: Symbols.picture_in_picture_alt_rounded, title: 'Plovoucí přehrávač', how: '', hint: Hint.floatingPlayer),
  ]),
  ('Další', [
    (
      icon: Symbols.graphic_eq_rounded,
      title: 'Co to hraje? (Shazam)',
      how: 'Profil › Shazam – pozná skladbu, která hraje kolem, a uloží ji na později.',
      hint: null,
    ),
    (
      icon: Symbols.music_note_rounded,
      title: 'Ladička',
      how: 'Profil › Ladička – naladíš kytaru nebo jiný nástroj.',
      hint: null,
    ),
  ]),
];

class FeaturesScreen extends ConsumerStatefulWidget {
  const FeaturesScreen({super.key});

  @override
  ConsumerState<FeaturesScreen> createState() => _FeaturesScreenState();
}

class _FeaturesScreenState extends ConsumerState<FeaturesScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    String how(_Feature f) => f.hint != null ? hintTexts[f.hint]! : f.how;
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
        child: TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Symbols.search_rounded), hintText: 'Hledat funkci'),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
    ];
    for (final (title, features) in _sections) {
      final shown = [
        for (final f in features)
          if (q.isEmpty || f.title.toLowerCase().contains(q) || how(f).toLowerCase().contains(q)) f,
      ];
      if (shown.isEmpty) continue;
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
        child: Text(title, style: theme.textTheme.titleMedium),
      ));
      for (final f in shown) {
        children.add(ListTile(
          leading: Icon(f.icon, fill: 1),
          title: Text(f.title),
          subtitle: Text(how(f)),
        ));
      }
    }
    children.add(SizedBox(height: navBottomInset(context)));
    return Scaffold(
      appBar: const SectionAppBar('Co Opentify umí'),
      body: ListView(children: children),
    );
  }
}
