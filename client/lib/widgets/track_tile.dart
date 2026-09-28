import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/availability.dart';
import '../models/recording_model.dart';
import '../state/artwork_provider.dart';
import '../state/audio_player_controller.dart';
import '../state/liked_songs_controller.dart';
import '../state/provisioning_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'media_card.dart' show ArtworkImage;
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
  });

  final RecordingModel recording;
  final int? leadingIndex;
  final String? subtitle;

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
    final provisioning = ref.watch(provisioningControllerProvider);
    final trackState = provisioning[recording.id];
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
            ? ref.watch(recordingArtworkProvider((releaseId: recording.releaseId, artistId: recording.artistId))).valueOrNull
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

    return switch (layout) {
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
          // Skladba nemá vlastní stránku -- název vede na její album (a tam
          // ji zvýrazní), bez alba na interpreta.
          onOpenDetail: selectionMode
              ? null
              : recording.releaseId != null
                  ? () => context.push('/releases/${recording.releaseId}?track=${recording.id}')
                  : recording.artistId != null
                      ? () => context.push('/artists/${recording.artistId}')
                      : null,
          onArtistTap: selectionMode ? null : artistTap,
          selectionMode: selectionMode,
          selected: selected,
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
    required this.onOpenDetail,
    required this.onArtistTap,
    required this.selectionMode,
    required this.selected,
  });

  final RecordingModel recording;
  final int? leadingIndex;
  final String? subtitle;
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
  final VoidCallback? onOpenDetail;
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
        child: Checkbox(value: w.selected, onChanged: (_) => w.onTap?.call()),
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

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
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
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Název vede na detail skladby, zbytek řádku přehrává
                        // -- stejný vzor jako Spotube/Spotify desktop.
                        _LinkText(
                          text: w.recording.title,
                          onTap: w.onOpenDetail,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: w.isPlaying ? theme.colorScheme.primary : null,
                          ),
                        ),
                        _LinkText(
                          text: w.subtitle ?? w.recording.durationLabel,
                          onTap: w.onArtistTap,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (!w.selectionMode) ...[
                    if (wide && w.recording.durationMs != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                        child: Text(w.recording.durationLabel, style: theme.textTheme.bodySmall),
                      ),
                    IconButton(
                      icon: Icon(
                        w.isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
                        fill: w.isLiked ? 1 : 0,
                        color: w.isLiked ? Colors.redAccent : null,
                      ),
                      tooltip: w.isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
                      onPressed: w.onToggleLike,
                    ),
                    _Trailing(
                      isAvailable: w.isAvailable,
                      isInFlight: w.isInFlight,
                      isFailed: w.isFailed,
                      pct: w.pct,
                      onTap: w.onTap,
                      onRetry: w.onRetry,
                    ),
                    if (wide)
                      IconButton(
                        icon: const Icon(Symbols.more_horiz_rounded),
                        tooltip: 'Další možnosti',
                        onPressed: w.onLongPress,
                      ),
                  ],
                ],
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
    final radius = isPlaying ? AppRadii.lg : AppRadii.md;

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      decoration: ShapeDecoration(
        color: isPlaying ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHigh,
        shape: AppShapes.of(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
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
                              isAvailable ? Symbols.play_circle_rounded : Symbols.download_rounded,
                              color: Colors.white,
                              shadows: const [Shadow(blurRadius: 6)],
                            ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(recording.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    _LinkText(
                      text: subtitle ?? recording.durationLabel,
                      onTap: onArtistTap,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (animationIndex != null) {
      card = card
          .animate(delay: (animationIndex! * 60).ms)
          .fadeIn(duration: 300.ms, curve: Curves.easeOut)
          .slideY(begin: 0.08, end: 0, duration: 300.ms, curve: Curves.easeOutCubic);
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
    if (isInFlight) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, value: pct == null ? null : pct! / 100),
      );
    }
    if (isAvailable) {
      return IconButton(icon: const Icon(Symbols.play_circle_rounded), tooltip: 'Přehrát', onPressed: onTap);
    }
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
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
