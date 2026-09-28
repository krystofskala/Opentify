
import 'package:flutter_animate/flutter_animate.dart';
// Flutter má od 3.47 vlastní `RepeatMode` (`RepeatingAnimationBuilder`) --
// skrytý, ať nekoliduje s naším (`AudioPlayerState.repeatMode`).
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/audio_player_controller.dart';
import '../../state/liked_songs_controller.dart';
import '../../state/provisioning_controller.dart';
import '../../theme/accent_color.dart';
import '../../theme/shapes.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/glass/expressive_shapes.dart';
import '../../widgets/glass/glass.dart';
import '../../widgets/lyrics_panel.dart';
import '../../widgets/state_views.dart';
import '../../widgets/wavy_seek_bar.dart';
import 'player_more_sheet.dart';
import '../../widgets/net_image.dart';

/// Celoobrazovkový přehrávač po rozbalení `PlayerBar` -- inspirováno
/// PixelPlayerem (github.com/brendmung/PixelPlayer) a Finampem: velký
/// zaoblený obal, pozadí tónované dominantní barvou obalu
/// (`AudioPlayerState.accentColor`, stejná barva jako v `PlayerBar`/M3 tématu
/// appky), vlnovkový seek bar (`WavySeekBar`, port PixelPlayerova
/// `WavySliderExpressive`), Předchozí/Další (`AudioPlayerState.queue`,
/// layout podle Finampova `PlayerButtons`) a synchronizovaný text
/// (`LyricsPanel`, z veřejného LRCLIB přes backend proxy).
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  // Směr posledního swipe gesta na obalu -- řídí, ze které strany "přijede"
  // vstupní animace dalšího/předchozího obalu (`_SwipeableArtwork` níž), ať
  // gesto vypadá jako skutečné odsunutí karty, ne jen jako záměna obrázku.
  double _slideDirection = 0;

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    final theme = Theme.of(context);
    final targetAccent = playback.accentColor ?? theme.colorScheme.primary;

    if (nowPlaying == null) {
      // Teoreticky nedosažitelné (PlayerBar se schová, když nic nehraje, a
      // jen ona sem naviguje), ale bez závislosti na kontextu volajícího.
      return Scaffold(appBar: AppBar(), body: const EmptyState(message: 'Nic nehraje.'));
    }

    final duration = playback.duration ?? Duration.zero;
    final positionMs =
        playback.position.inMilliseconds.clamp(0, duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds);
    final isWide = MediaQuery.of(context).size.width >= 720;

    final provisioningState = ref.watch(provisioningControllerProvider)[nowPlaying.recordingId];
    final isProvisioning = provisioningState?.isInFlight ?? false;
    final provisioningPct = provisioningState?.pct;

    return AnimatedAccent(
      color: targetAccent,
      builder: (context, accent) => Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Plná barva vždy vespod -- přehrávač nemá mít gradient pozadí
          // appky, ani na okamžik, než se obal načte.
          // Pozadí appky (živé, v barvě skladby) pod JEDINOU hustě namrzlou
          // vrstvou přes celou obrazovku -- obal už není pozadím, jen velký
          // náhled uprostřed. Vrstva se prolíná s animací vysunutí trasy, ať
          // při přechodu nic neproblikne.
          FadeTransition(
            opacity: CurvedAnimation(
              parent: ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation,
              curve: Curves.easeOut,
            ),
            child: GlassContainer.frosted(
              borderRadius: BorderRadius.zero,
              tint: accent,
              showEdgeHighlight: false,
              fit: StackFit.expand,
              child: const SizedBox.expand(),
            ),
          ),
          // Bílý text musí být čitelný i na světlém pozadí -- HIG Materials
          // (clear varianta): "If the underlying content is bright, consider
          // adding a dark dimming layer of 35% opacity."
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark ? 0.18 : GlassTokens.mediaDimming,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Symbols.keyboard_arrow_down_rounded, color: Colors.white, size: 32),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Expanded(
                        child: Text(
                          'PŘEHRÁVÁ SE',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2),
                        ),
                      ),
                      Builder(
                        builder: (context) {
                          final isLiked = ref.watch(
                            likedSongsControllerProvider.select(
                              (s) => s.valueOrNull?.contains(nowPlaying.recordingId) ?? false,
                            ),
                          );
                          return IconButton(
                            icon: Icon(
                              isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
                              color: isLiked ? Colors.redAccent : Colors.white,
                              size: 24,
                            ),
                            tooltip: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
                            onPressed: () => ref
                                .read(likedSongsControllerProvider.notifier)
                                .toggle(nowPlaying.recordingId),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Symbols.lyrics_rounded, color: Colors.white, size: 24),
                        tooltip: 'Text skladby',
                        onPressed: () => showLyricsPanel(context, recordingId: nowPlaying.recordingId, accentColor: accent),
                      ),
                      IconButton(
                        icon: const Icon(Symbols.more_vert_rounded, color: Colors.white, size: 24),
                        tooltip: 'Další možnosti',
                        onPressed: () => showPlayerMoreSheet(context),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: isWide ? 480 : double.infinity),
                        child: Column(
                          key: ValueKey(nowPlaying.recordingId),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              // Swipe doleva -> další skladba, doprava ->
                              // předchozí -- stejné gesto jako horizontální
                              // listování v galerii. Práh na rychlosti gesta
                              // (ne jen na vzdálenosti), ať krátký rychlý
                              // švih taky prohodí skladbu.
                              onHorizontalDragEnd: (details) {
                                final velocity = details.primaryVelocity ?? 0;
                                if (velocity < -250 && playback.hasNext) {
                                  setState(() => _slideDirection = 1);
                                  ref.read(audioPlayerControllerProvider.notifier).next();
                                } else if (velocity > 250 && playback.hasPrevious) {
                                  setState(() => _slideDirection = -1);
                                  ref.read(audioPlayerControllerProvider.notifier).previous();
                                }
                              },
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: ClipPath(
                                  clipper: ShapeBorderClipper(shape: AppShapes.of(24)),
                                  child: nowPlaying.artworkUrl != null
                                      ? NetImage(url: nowPlaying.artworkUrl!)
                                      : Container(
                                          color: Colors.white.withValues(alpha: 0.15),
                                          child: const Icon(Symbols.music_note_rounded, color: Colors.white, size: 96),
                                        ),
                                ),
                              ),
                            )
                                .animate()
                                .fadeIn(duration: 350.ms)
                                .slideX(begin: _slideDirection * 0.25, end: 0, curve: Curves.easeOut)
                                .scale(begin: const Offset(0.94, 0.94), curve: Curves.easeOut),
                            const SizedBox(height: 32),
                            GestureDetector(
                              onTap: nowPlaying.releaseId == null
                                  ? null
                                  : () => context.push('/releases/${nowPlaying.releaseId}'),
                              child: Text(
                                nowPlaying.title,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (nowPlaying.artistName != null || nowPlaying.artistId != null) ...[
                              const SizedBox(height: 8),
                              GestureDetector(
                                onTap: nowPlaying.artistId == null
                                    ? null
                                    : () => context.push('/artists/${nowPlaying.artistId}'),
                                child: Text(
                                  nowPlaying.artistName ?? 'Zobrazit interpreta',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 16,
                                    decoration:
                                        nowPlaying.artistId != null ? TextDecoration.underline : null,
                                    decorationColor: Colors.white.withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                            ],
                            if (isProvisioning) ...[
                              const SizedBox(height: 8),
                              Text(
                                provisioningState!.statusLabel,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                              ),
                            ],
                            const SizedBox(height: 28),
                            // Ovládání na světlejším skleněném panelu -- bez
                            // vlastního rozmazání (leží na už namrzlém skle).
                            GlassContainer(
                              blur: false,
                              baseFill: false,
                              emphasis: GlassTokens.emphasis,
                              borderRadius: BorderRadius.circular(28),
                              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                            WavySeekBar(
                              progress: duration.inMilliseconds == 0 ? 0 : positionMs / duration.inMilliseconds,
                              isPlaying: playback.isPlaying,
                              onChangeEnd: duration.inMilliseconds == 0
                                  ? null
                                  : (value) => ref
                                      .read(audioPlayerControllerProvider.notifier)
                                      .seek(Duration(milliseconds: (value * duration.inMilliseconds).round())),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_formatDuration(playback.position), style: const TextStyle(color: Colors.white70)),
                                  Text(_formatDuration(duration), style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            // Layout podle Finampova `PlayerButtons` --
                            // spaceEvenly řádek, velké tlačítko uprostřed,
                            // jednoduché ikony pro skok po stranách. Shuffle/
                            // repeat na okrajích -- stejná řada ovladačů, jakou
                            // má Finamp i většina ostatních přehrávačů.
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                IconButton(
                                  icon: Icon(Symbols.shuffle_rounded,
                                      color: playback.shuffleEnabled ? accent : Colors.white54, size: 22),
                                  tooltip: 'Náhodné přehrávání',
                                  onPressed: () => ref.read(audioPlayerControllerProvider.notifier).toggleShuffle(),
                                ),
                                IconButton(
                                  icon: const Icon(Symbols.skip_previous_rounded, color: Colors.white, size: 34),
                                  onPressed: playback.hasPrevious || playback.position > const Duration(seconds: 3)
                                      ? () => ref.read(audioPlayerControllerProvider.notifier).previous()
                                      : null,
                                ),
                                // M3 Expressive: play = "cookie" tvar, pauza =
                                // squircle -- tvar pružinou morfuje se stavem.
                                GlassPressable(
                                  onPressed: playback.isBuffering
                                      ? null
                                      : () => ref.read(audioPlayerControllerProvider.notifier).togglePlayPause(),
                                  shape: const CircleBorder(),
                                  semanticLabel: playback.isPlaying ? 'Pozastavit' : 'Přehrát',
                                  child: ExpressiveMorph(
                                    size: 96,
                                    color: Colors.white,
                                    shape: playback.isPlaying
                                        ? const ExpressiveShape.squircle()
                                        : const ExpressiveShape.cookie(lobes: 9, depth: 0.09),
                                    child: playback.isBuffering
                                        ? (isProvisioning && provisioningPct != null
                                            ? SizedBox.square(
                                                dimension: 44,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 3,
                                                  color: accent,
                                                  value: provisioningPct / 100,
                                                ),
                                              )
                                            : ExpressiveLoadingIndicator(size: 44, color: accent))
                                        : Icon(
                                            playback.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                                            size: 48,
                                            color: accent,
                                          ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Symbols.skip_next_rounded, color: Colors.white, size: 34),
                                  onPressed: playback.hasNext
                                      ? () => ref.read(audioPlayerControllerProvider.notifier).next()
                                      : null,
                                ),
                                IconButton(
                                  icon: Icon(
                                    playback.repeatMode == RepeatMode.one ? Symbols.repeat_one_rounded : Symbols.repeat_rounded,
                                    color: playback.repeatMode == RepeatMode.off ? Colors.white54 : accent,
                                    size: 22,
                                  ),
                                  tooltip: 'Opakování',
                                  onPressed: () => ref.read(audioPlayerControllerProvider.notifier).cycleRepeatMode(),
                                ),
                              ],
                            ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
