import 'toast.dart';
import 'like_heart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../data/listen_later_repository.dart' show LaterKind;
import '../models/availability.dart';
import '../models/recording_model.dart';
import '../state/artwork_provider.dart';
import '../state/audio_player_controller.dart';
import '../state/heard_controller.dart';
import '../state/liked_songs_controller.dart';
import '../state/listen_later_controller.dart';
import '../state/provisioning_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import '../theme/shapes.dart';
import 'media_card.dart' show ArtworkImage;
import 'queue_swipe.dart';
import 'track_actions.dart';
import 'glass/expressive_shapes.dart';

enum TrackTileLayout { row, card }

/// Jedna nahrávka -- nahrazuje dřívější `RecordingTile` (řádek), Home's
/// `_TrackCard` (karta, jediné místo s `elevation: 2`) a Library's `_SongCard`
/// (karta, `elevation: 0`), které se lišily poloměry/paddingem/přístupem k
/// "elevaci" bez jednoho sdíleného důvodu. Teď jeden widget, dva `layout`y.
///
/// Chování se odvíjí od živého provisioning stavu (`ProvisioningController`),
/// ne jen od statického `availability` z katalogové odpovědi:
///   - `available`        -> ikona přehrání, klik spustí playback.
///   - `provisionable`     -> ikona stažení, klik zavolá `POST /provision`.
///   - probíhá provisioning -> spinner (a `pct` z `job.progress`, pokud přišel).
///   - `FAILED`            -> ikona chyby, klik zkusí provisioning znovu.
///
/// Dlaždice právě hrající skladby morphuje poloměr směrem k plné pilulce a
/// podbarví se `primaryContainer` -- PixelPlayerův motiv (`row`: 22dp->50dp,
/// `thumb`: 10dp->50dp), teď navíc dává appce stav "tohle právě hraje", který
/// dřív nikde neexistoval.
class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.recording,
    this.leadingIndex,
    this.subtitle,
    this.albumArtUrl,
    this.artistName,
    this.queueRecordings,
    this.sourceLabel,
    this.layout = TrackTileLayout.row,
    this.animationIndex,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectedChanged,
    this.extraMenuActions = const [],
    this.badge,
  });

  final RecordingModel recording;
  final int? leadingIndex;
  final String? subtitle;

  /// Malá značka před podtitulkem (např. „Open Shazam“ v Poslechnout později).
  final Widget? badge;

  /// Volitelný kontext pro `PlayerBar` (Release/Artist/Profil ho znají,
  /// doporučené seznamy na Home ne -- lišta se bez nich obejde, jen ukáže
  /// méně metadat a šedý placeholder obalu).
  final String? albumArtUrl;
  final String? artistName;

  /// Sourozenci téhle skladby v seznamu (celý tracklist alba, načtená stránka
  /// knihovny...) -- umožní Předchozí/Další v `NowPlayingScreen`. `null`
  /// znamená, že skladba hraje osamoceně (fronta pak má jen jeden prvek).
  final List<RecordingModel>? queueRecordings;

  /// "Přehráváno z X" -- viz `AudioPlayerState.queueSourceLabel`.
  final String? sourceLabel;

  final TrackTileLayout layout;

  /// Pořadí v horizontální řadě/mřížce pro staggered nástupní animaci
  /// (`flutter_animate`) -- `null` (výchozí, řádkový seznam knihovny) tuhle
  /// animaci vypne, tisíce položek by ji jen zpomalily bez viditelného přínosu.
  final int? animationIndex;

  /// Hromadný výběr (`TrackCollectionToolbar`) -- tap přepíná výběr místo
  /// přehrání, vlevo zaškrtávátko, vpravo nic.
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectedChanged;

  /// Akce navíc do sdíleného kontextového menu (např. "Odebrat z playlistu").
  final List<TrackMenuAction> extraMenuActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Jen stav TÉHLE skladby -- dřív každý průběh libovolného stahování
    // překreslil všechny viditelné řádky.
    final trackState = ref.watch(provisioningControllerProvider.select((m) => m[recording.id]));
    final status = trackState?.status;
    final isAvailable = status == 'AVAILABLE' || recording.availability == Availability.available;
    final isInFlight = trackState?.isInFlight ?? false;
    final isFailed = trackState?.isFailed ?? false;
    final isPlaying = ref.watch(
      audioPlayerControllerProvider.select((s) => s.nowPlaying?.recordingId == recording.id),
    );
    final isLiked = ref.watch(
      likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(recording.id) ?? false),
    );

    // Volající (Release/Artist) obal už zná a pošle ho přímo -- fallback
    // dotaz na `recordingArtworkProvider` (album, jinak interpret) se
    // spouští, jen když ho po ruce nemáme (doporučené seznamy na Home,
    // search výsledky).
    final resolvedArtUrl = albumArtUrl ??
        (recording.releaseId != null || recording.artistId != null
            ? ref
                .watch(recordingArtworkProvider((releaseId: recording.releaseId, artistId: recording.artistId)))
                .valueOrNull
            : null);

    // Volající většinou žádný `subtitle` nepošle (Domů, Knihovna, Oblíbené,
    // playlisty) -- bez tohohle by druhý řádek skončil u délky skladby a
    // interpret by se v seznamu nezobrazil vůbec (nahlášeno jako "všude
    // chybí interpret"). Explicitní `subtitle` (např. Domů's "N poslechů" u
    // trending karet) má pořád přednost.
    final effectiveSubtitle = subtitle ?? recording.artistName ?? artistName;
    // Jméno interpreta je proklikávací všude stejně -- jen když druhý řádek
    // opravdu JE jméno interpreta (ne "N poslechů" apod.) a máme kam jít.
    final artistTap = subtitle == null && effectiveSubtitle != null && recording.artistId != null
        ? () => context.push('/artists/${recording.artistId}')
        : null;

    // Vždy jde přes `AudioPlayerController.playTrack/playQueue`, i pro
    // ještě nestažené skladby -- `_playCurrent()` v něm teď samo zavolá
    // `provision()`, počká na `track.available` a pak spustí přehrávání,
    // takže tenhle tap nemusí čekání řešit zvlášť (viz jeho docstring).
    // Bez `isInFlight` guardu by opakovaný tap uprostřed čekání jen zbytečně
    // restartoval `AudioPlayerState` (queue/pozice) se stejnou skladbou.
    final VoidCallback? onTap = selectionMode
        ? () => onSelectedChanged?.call(!selected)
        : (isInFlight ? null : () => _play(ref, resolvedArtUrl));
    void onLongPress() {
      if (selectionMode) {
        onSelectedChanged?.call(!selected);
        return;
      }
      showTrackActionsSheet(
        context,
        recording: recording,
        artworkUrl: resolvedArtUrl,
        artistNameFallback: artistName,
        extraActions: extraMenuActions,
      );
    }

    void enqueue({required bool next}) {
      final controller = ref.read(audioPlayerControllerProvider.notifier);
      final info = nowPlayingInfoFor(recording, artworkUrl: resolvedArtUrl, artistNameFallback: artistName);
      if (next) {
        controller.playNext(info);
      } else {
        controller.addToQueue(info);
      }
      // Stejné znění jako v menu skladby.
      toast(context, next ? 'Jako další: ${recording.title}' : 'Do fronty: ${recording.title}');
    }

    final row = switch (layout) {
      TrackTileLayout.row => _RowTile(
          recording: recording,
          leadingIndex: leadingIndex,
          subtitle: effectiveSubtitle,
          resolvedArtUrl: resolvedArtUrl,
          isAvailable: isAvailable,
          isInFlight: isInFlight,
          isFailed: isFailed,
          isPlaying: isPlaying,
          isLiked: isLiked,
          pct: trackState?.pct,
          onTap: onTap,
          onLongPress: onLongPress,
          onRetry: () => _play(ref, resolvedArtUrl),
          onToggleLike: () => ref.read(likedSongsControllerProvider.notifier).toggle(recording.id),
          onArtistTap: selectionMode ? null : artistTap,
          selectionMode: selectionMode,
          selected: selected,
          badge: badge,
        ),
      TrackTileLayout.card => _CardTile(
          recording: recording,
          subtitle: effectiveSubtitle,
          resolvedArtUrl: resolvedArtUrl,
          isAvailable: isAvailable,
          isInFlight: isInFlight,
          isPlaying: isPlaying,
          onTap: onTap,
          onLongPress: onLongPress,
          onArtistTap: artistTap,
          animationIndex: animationIndex,
        ),
    };
    // Swipe doprava/doleva = začátek/konec fronty (Apple Music) -- jen řádky
    // mimo hromadný výběr; karty v rozjetých řadách se táhnou vodorovně.
    if (layout != TrackTileLayout.row || selectionMode) return row;
    return QueueSwipe(
      onPlayNext: () => enqueue(next: true),
      onPlayLast: () => enqueue(next: false),
      // Dlouhý tah doleva = "Poslechnout později" (přepínač).
      onLater: () => ref.read(listenLaterProvider.notifier).toggle(context, LaterKind.track, recording.id),
      child: row,
    );
  }

  void _play(WidgetRef ref, String? resolvedArtUrl) {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    final siblings = queueRecordings;
    if (siblings != null && siblings.isNotEmpty) {
      // Sdílený `albumArtUrl` (Release/Profil) jde ke všem sourozencům --
      // pro ně je to stejný obal. Bez něj (Home rails/Search, kde má každá
      // skladba jiný obal) dostane vlastní obal jen tenhle tapnutý kus;
      // ostatním ho doplní `AudioPlayerController._extractAccentColor`, až
      // na ně přijde řada -- N providerů navíc jen kvůli frontě by se
      // nevyplatilo.
      // Per-skladba jméno má přednost před sdíleným `artistName` -- na
      // kompilačním albu můžou mít sourozenci různé interprety.
      final infos = siblings
          .map((r) => nowPlayingInfoFor(
                r,
                artworkUrl: r.id == recording.id ? resolvedArtUrl : albumArtUrl,
                artistNameFallback: artistName,
              ))
          .toList();
      final index = siblings.indexWhere((r) => r.id == recording.id);
      controller.playQueue(infos, index < 0 ? 0 : index, sourceLabel: sourceLabel);
    } else {
      controller.playTrack(
        nowPlayingInfoFor(recording, artworkUrl: resolvedArtUrl, artistNameFallback: artistName),
        sourceLabel: sourceLabel,
      );
    }
  }
}

class _RowTile extends StatefulWidget {
  const _RowTile({
    required this.recording,
    required this.leadingIndex,
    required this.subtitle,
    this.badge,
    required this.resolvedArtUrl,
    required this.isAvailable,
    required this.isInFlight,
    required this.isFailed,
    required this.isPlaying,
    required this.isLiked,
    required this.pct,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onToggleLike,
    required this.onArtistTap,
    required this.selectionMode,
    required this.selected,
  });

  final RecordingModel recording;
  final int? leadingIndex;
  final String? subtitle;
  final Widget? badge;
  final String? resolvedArtUrl;
  final bool isAvailable;
  final bool isInFlight;
  final bool isFailed;
  final bool isPlaying;
  final bool isLiked;
  final int? pct;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;
  final VoidCallback onToggleLike;
  final VoidCallback? onArtistTap;
  final bool selectionMode;
  final bool selected;

  @override
  State<_RowTile> createState() => _RowTileState();
}

class _RowTileState extends State<_RowTile> {
  // Desktop hover -- náhled/číslo stopy se prohodí za ikonu přehrání
  // (UX vzor ze Spotube's `track_tile.dart`, vlastní implementace).
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final theme = Theme.of(context);
    final radius = w.isPlaying ? AppRadii.pill : AppRadii.md;
    final showHoverPlay = _hovering && !w.selectionMode && !w.isInFlight;
    final wide = MediaQuery.sizeOf(context).width >= 600;

    final Widget leading;
    if (w.selectionMode) {
      leading = SizedBox(
        width: 44,
        height: 44,
        // Kulaté zaškrtnutí jako výběr v Apple Music/Fotkách (ne hranatý
        // materiálový checkbox).
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: w.selected ? theme.colorScheme.primary : Colors.transparent,
              border: Border.all(
                color: w.selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                width: 1.5,
              ),
            ),
            child: w.selected ? Icon(Symbols.check_rounded, size: 16, weight: 600, color: theme.colorScheme.onPrimary) : null,
          ),
        ),
      );
    } else if (w.leadingIndex != null) {
      leading = SizedBox(
        width: 28,
        child: showHoverPlay
            ? Icon(Symbols.play_arrow_rounded, size: 20, color: theme.colorScheme.primary)
            : w.isPlaying
                ? Icon(Symbols.graphic_eq_rounded, size: 18, color: theme.colorScheme.primary)
                : Text('${w.leadingIndex}', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      );
    } else {
      leading = _Thumbnail(artworkUrl: w.resolvedArtUrl, isPlaying: w.isPlaying, showPlayOverlay: showHoverPlay);
    }

    final Color background;
    if (w.selected) {
      background = theme.colorScheme.primaryContainer.withValues(alpha: 0.6);
    } else if (w.isPlaying) {
      background = theme.colorScheme.primaryContainer;
    } else if (_hovering) {
      background = theme.colorScheme.onSurface.withValues(alpha: 0.05);
    } else {
      background = Colors.transparent;
    }
    final onTinted = (w.selected || w.isPlaying) ? theme.colorScheme.onPrimaryContainer : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: Motion.state.duration,
        curve: Motion.state,
        decoration: ShapeDecoration(color: background, shape: AppShapes.of(radius)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: AppShapes.of(radius),
            onTap: w.onTap,
            onLongPress: w.onLongPress,
            onSecondaryTap: w.onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              child: IconTheme.merge(
                data: IconThemeData(color: onTinted),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: onTinted),
                  child: Row(
                    children: [
                      leading,
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Název NEvede na album -- při tapnutí na skladbu
                            // v seznamu se omylem otevíralo album (živě
                            // nahlášeno). Album je v menu skladby a v přehrávači.
                            _LinkText(
                              text: w.recording.title,
                              onTap: null,
                              // Na podbarveném řádku `onPrimaryContainer`, ne
                              // `primary` -- u černobílých obalů (monochromní
                              // schéma) byly obě skoro bílé a text zmizel.
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: onTinted,
                                fontWeight: w.isPlaying ? FontWeight.w600 : null,
                              ),
                            ),
                            Row(
                              children: [
                                if (w.badge case final badge?) ...[badge, const SizedBox(width: 6)],
                                Flexible(
                                  child: HeardBuilder(
                                    recordingId: w.recording.id,
                                    // Zabarvuje se jen délka, ne interpret.
                                    builder: (context, heard) => _LinkText(
                                      text: w.subtitle ?? w.recording.durationLabel,
                                      onTap: w.onArtistTap,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: onTinted?.withValues(alpha: 0.75) ??
                                            (heard && w.subtitle == null
                                                ? heardColor(theme)
                                                : theme.colorScheme.onSurfaceVariant),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (!w.selectionMode) ...[
                        // Pevný sloupec -- dřív se objevoval jen u části řádků
                        // a sloupce pod sebou "skákaly" (design audit #7).
                        if (wide)
                          SizedBox(
                            width: 52,
                            child: HeardBuilder(
                              recordingId: w.recording.id,
                              builder: (context, heard) => Text(
                                // Neznámá délka = prázdné místo, ne sloupec "--:--".
                                w.recording.durationMs != null ? w.recording.durationLabel : '',
                                textAlign: TextAlign.right,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  color: heard && onTinted == null ? heardColor(theme) : null,
                                ),
                              ),
                            ),
                          ),
                        // Stahování vlevo od srdíčka, srdíčko u pravé hrany --
                        // stažené skladby ikonu nemají a srdíčka pořád lícují.
                        // Na širokém pevný slot -- jinak ikona stahování
                        // posouvala sloupec délek (nelícovaly pod sebou).
                        SizedBox(
                          width: wide ? 48 : null,
                          child: Center(
                            widthFactor: wide ? null : 1,
                            heightFactor: 1,
                            child: _Trailing(
                              isAvailable: w.isAvailable,
                              isInFlight: w.isInFlight,
                              isFailed: w.isFailed,
                              pct: w.pct,
                              onTap: w.onTap,
                              onRetry: w.onRetry,
                            ),
                          ),
                        ),
                        LikeHeart(recordingId: w.recording.id),
                        // ⋯ i na telefonu (audit UI: menu šlo otevřít jen
                        // dlouhým stiskem, který nikdo nehledá).
                        IconButton(
                          icon: const Icon(Symbols.more_horiz_rounded),
                          tooltip: 'Další možnosti',
                          visualDensity: wide ? null : VisualDensity.compact,
                          onPressed: w.onLongPress,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text, který se při najetí myší podtrhne a je klikatelný -- sdílený pro
/// název skladby (detail) a jméno interpreta (profil interpreta).
class _LinkText extends StatefulWidget {
  const _LinkText({required this.text, required this.onTap, this.style});

  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;

  @override
  State<_LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<_LinkText> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? const TextStyle();
    final text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(decoration: _hover ? TextDecoration.underline : TextDecoration.none),
    );
    if (widget.onTap == null) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, child: text),
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.recording,
    required this.subtitle,
    required this.resolvedArtUrl,
    required this.isAvailable,
    required this.isInFlight,
    required this.isPlaying,
    required this.onTap,
    required this.onLongPress,
    required this.onArtistTap,
    this.animationIndex,
  });

  final RecordingModel recording;
  final String? subtitle;
  final String? resolvedArtUrl;
  final bool isAvailable;
  final bool isInFlight;
  final bool isPlaying;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onArtistTap;
  final int? animationIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Jako karty alb/playlistů: obal + text pod ním, bez šedého podkladu
    // (ten jinde na Domů není -- živě nahlášeno). Hrající skladba: ikona
    // ekvalizéru na obalu a název v barvě akcentu.
    final artShape = AppShapes.of(AppRadii.md);
    Widget card = Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: artShape,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipPath(
                clipper: ShapeBorderClipper(shape: artShape),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ArtworkImage(url: resolvedArtUrl, icon: Symbols.music_note_rounded, iconSize: 36),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: isInFlight
                          ? const ExpressiveLoadingIndicator(size: 28, color: Colors.white)
                          : Icon(
                              isPlaying
                                  ? Symbols.graphic_eq_rounded
                                  : isAvailable
                                      ? Symbols.play_circle_rounded
                                      : Symbols.download_rounded,
                              color: Colors.white,
                              shadows: const [Shadow(blurRadius: 6)],
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, AppSpacing.xs, 2, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recording.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isPlaying ? theme.colorScheme.primary : null,
                      fontWeight: isPlaying ? FontWeight.w700 : null,
                    ),
                  ),
                  HeardBuilder(
                    recordingId: recording.id,
                    builder: (context, heard) => _LinkText(
                      text: subtitle ?? recording.durationLabel,
                      onTap: onArtistTap,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: heard && subtitle == null ? heardColor(theme) : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (animationIndex != null) {
      card = card
          .animate(delay: (animationIndex! * 60).ms)
          .fadeIn(duration: Motion.state.duration, curve: Motion.state)
          .slideY(begin: 0.08, end: 0, duration: Motion.enter.duration, curve: Motion.enter);
    }
    return card;
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    required this.isAvailable,
    required this.isInFlight,
    required this.isFailed,
    required this.pct,
    required this.onTap,
    required this.onRetry,
  });

  final bool isAvailable;
  final bool isInFlight;
  final bool isFailed;
  final int? pct;
  final VoidCallback? onTap;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // Vždy stejná šířka jako tlačítko (48) -- při stahování se srdíčko
    // dřív posunulo do strany (design audit #7).
    if (isInFlight) {
      return SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            // Podklad + při 0 % točení -- dřív byl kroužek na 0 % neviditelný a
            // řádek vypadal, jako by u něj žádné tlačítko nebylo.
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: pct == null || pct == 0 ? null : pct! / 100,
              backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
            ),
          ),
        ),
      );
    }
    // Dostupná skladba: bez ikony (klepnutí na řádek přehraje), jen místo.
    if (isAvailable) return const SizedBox(width: 48, height: 48);
    return IconButton(
      icon: Icon(isFailed ? Symbols.refresh_rounded : Symbols.download_rounded),
      tooltip: isFailed ? 'Zkusit znovu' : 'Obstarat a přehrát',
      onPressed: onRetry,
    );
  }
}

/// Zaoblený obal skladby, nebo přechodový placeholder s notovou ikonou, když
/// volající kontext žádný obal nemá. Poloměr morphuje k plné pilulce (tzn.
/// ke kruhu, na čtvercovém náhledu) při přehrávání -- stejný motiv jako
/// `_RowTile`'s vnější kontejner, jen o úroveň níž.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.artworkUrl, required this.isPlaying, this.showPlayOverlay = false});

  final String? artworkUrl;
  final bool isPlaying;
  final bool showPlayOverlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = isPlaying ? AppRadii.pill : AppRadii.sm;
    // Náhled se při přehrávání přelévá do kruhu -- pružina jako zbytek appky.
    return AnimatedContainer(
      duration: Motion.enter.duration,
      curve: Motion.enter,
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(shape: AppShapes.of(radius)),
      child: showPlayOverlay
          ? Stack(
              fit: StackFit.expand,
              children: [
                _artwork(theme),
                const ColoredBox(color: Colors.black45),
                const Icon(Symbols.play_arrow_rounded, color: Colors.white, size: 24),
              ],
            )
          : _artwork(theme),
    );
  }

  Widget _artwork(ThemeData theme) => ArtworkImage(url: artworkUrl, icon: Symbols.music_note_rounded, iconSize: 18);
}

/// Nenápadná trvalá značka "poslechnuto celé": délka skladby v barvě
/// motivu místo šedé -- nic navíc, jen jiný odstín
/// (živě chtěné: tečka byla moc). Sleduje jen svou skladbu, ať se při
/// novém poslechu nepřestavuje celý seznam.
class HeardBuilder extends ConsumerWidget {
  const HeardBuilder({super.key, required this.recordingId, required this.builder});

  final String recordingId;
  final Widget Function(BuildContext context, bool heard) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      builder(context, ref.watch(heardProvider.select((s) => s.contains(recordingId))));
}

Color heardColor(ThemeData theme) => theme.colorScheme.primary.withValues(alpha: 0.85);
