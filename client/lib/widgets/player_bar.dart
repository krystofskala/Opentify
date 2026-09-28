import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/audio_player_controller.dart';
import '../state/liked_songs_controller.dart';
import '../state/provisioning_controller.dart';
import '../theme/accent_color.dart';
import '../theme/glass_tokens.dart';
import 'glass/expressive_shapes.dart';
import 'glass_container.dart';
import 'wavy_seek_bar.dart';
import 'net_image.dart';

/// Perzistentní "Liquid Glass" lišta přehrávače -- rozostřený obal alba na
/// pozadí, přes něj poloprůhledná skleněná vrstva (`BackdropFilter`). Vkládá
/// se do `bottomNavigationBar` slotu na každé obrazovce, kde má být vidět
/// (viz `HomeShell`, `ReleaseScreen`, `ArtistScreen`). Když nic nehraje,
/// nezabírá žádné místo.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key, this.shadow = true});

  /// `false` v `HomeShell` -- lišta leží těsně nad skleněnou navigací, dva
  /// stíny nad sebou by vypadaly jako špinavý pruh.
  final bool shadow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(audioPlayerControllerProvider);
    final nowPlaying = playback.nowPlaying;
    if (nowPlaying == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final targetAccent = playback.accentColor ?? theme.colorScheme.primary;
    final duration = playback.duration ?? Duration.zero;
    final positionMs = playback.position.inMilliseconds
        .clamp(0, duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds);
    final hasError = playback.error != null;
    final isLiked = ref.watch(
      likedSongsControllerProvider.select((s) => s.valueOrNull?.contains(nowPlaying.recordingId) ?? false),
    );

    // Odliší "čekám na dokončení obstarání" od obyčejného síťového bufferingu
    // už staženého souboru -- jen ten první má smysl popisovat textem/procenty,
    // viz `TrackProvisioningState.statusLabel`.
    final provisioningState = ref.watch(provisioningControllerProvider)[nowPlaying.recordingId];
    final isProvisioning = provisioningState?.isInFlight ?? false;
    final provisioningPct = provisioningState?.pct;

    void retry() {
      ref.read(audioPlayerControllerProvider.notifier).playTrack(nowPlaying);
    }

    return AnimatedAccent(
      color: targetAccent,
      builder: (context, accent) {
      // Popředí dle režimu -- na světlém namrzlém skle tmavé, na tmavém bílé
      // (HIG Accessibility: kontrast min. 4.5:1).
      final fg = Theme.of(context).colorScheme.onSurface;
      return Padding(
      // Stejné okraje jako tab bar pod ní (`GlassTokens.floatingMargin`).
      // Samostatně (detaily) nad home indikátorem; v `HomeShell` pod ní je
      // tab bar, který inset řeší sám (shell ho tady odebírá).
      padding: EdgeInsets.fromLTRB(
        GlassTokens.floatingMargin,
        0,
        GlassTokens.floatingMargin,
        8 + MediaQuery.paddingOf(context).bottom,
      ),
      // Pozadí appky pod hustě namrzlým sklem, jemně tónovaným barvou
      // skladby -- obal už NENÍ pozadím lišty (jen náhled vlevo).
      child: GlassContainer.frosted(
              borderRadius: BorderRadius.circular(26),
              tint: accent,
              shadow: shadow,
              // Inset je VNĚ kapsle (odsazení níž), ne uvnitř.
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Neinteraktivní ukazatel -- jen "at a glance" průběh, žádný
                  // Slider. Flutterí Slider si i přes vizuálně tenký track
                  // (trackHeight: 2) drží dotykovou plochu ~40dp vysokou, což
                  // v týhle 8px liště kradlo tapy určené pro rozbalení Now
                  // Playing pod ním -- klik na řádek dole místo expandu
                  // omylem seekoval skladbu. Reálný interaktivní seek slider
                  // zůstává jen v `NowPlayingScreen` (`interactive: false` tady
                  // gesta úplně vypne), vlnovka je ale stejná v obou -- viz
                  // `WavySeekBar` (port PixelPlayerova `WavySliderExpressive`).
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: duration.inMilliseconds == 0
                        ? (playback.isBuffering
                            ? SizedBox(
                                height: 8,
                                child: LinearProgressIndicator(
                                  minHeight: 2,
                                  backgroundColor: Colors.transparent,
                                  value: isProvisioning && provisioningPct != null ? provisioningPct / 100 : null,
                                ),
                              )
                            : const SizedBox(height: 8))
                        : WavySeekBar(
                            progress: positionMs / duration.inMilliseconds,
                            isPlaying: playback.isPlaying,
                            interactive: false,
                            height: 12,
                            strokeWidth: 2.5,
                            waveAmplitude: 2.5,
                            activeColor: fg,
                            inactiveColor: fg.withValues(alpha: 0.3),
                          ),
                  ),
                  GestureDetector(
                    // Švih nahoru rozbalí přehrávač stejně jako tap -- gesto
                    // z Musify's `MiniPlayer` (github.com/gokadzev/Musify,
                    // GPL-3.0). Jen `onVerticalDragUpdate`, žádný `onTap` tady
                    // -- ten nechává vnořenému `InkWell` níž, ať gesto
                    // neuloupí jeho ripple/tap.
                    onVerticalDragUpdate: (details) {
                      if ((details.primaryDelta ?? 0) < -10) context.push('/now-playing');
                    },
                    child: InkWell(
                    // Klik kdekoliv na řádek (mimo samotné tlačítko play/pause
                    // vpravo, které si tap vezme samo) rozbalí celoobrazovkový
                    // přehrávač -- "nejde zvětšit" byl reálný nedostatek dřívější
                    // verze, PixelPlayer to řeší přesně takhle (mini bar -> Now Playing).
                    onTap: () => context.push('/now-playing'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: nowPlaying.artworkUrl != null
                                  ? NetImage(url: nowPlaying.artworkUrl!)
                                  : Container(
                                      color:
                                          fg.withValues(alpha: 0.15),
                                      child: Icon(Symbols.music_note_rounded,
                                          color: fg, size: 20),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                GestureDetector(
                                  // Stejná disambiguace jako u jména interpreta
                                  // níž -- vnořený tap cíl uvnitř vnějšího
                                  // `InkWell` (rozbaluje Now Playing).
                                  onTap: nowPlaying.releaseId == null
                                      ? null
                                      : () => context.push('/releases/${nowPlaying.releaseId}'),
                                  child: Text(
                                    nowPlaying.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: fg,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                if (hasError)
                                  const Text(
                                    'Nepodařilo se přehrát -- klepni pro nový pokus',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: Colors.redAccent, fontSize: 12),
                                  )
                                else if (isProvisioning)
                                  Text(
                                    provisioningState!.statusLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 12),
                                  )
                                else if (nowPlaying.artistName != null || nowPlaying.artistId != null)
                                  GestureDetector(
                                    // Vnořený tap cíl uvnitř vnějšího `InkWell`
                                    // (rozbaluje Now Playing) -- Flutter gesto
                                    // disambiguuje samo, tap přesně na jméno
                                    // interpreta jde na jeho profil, tap kdekoliv
                                    // jinde v řádku pořád rozbaluje přehrávač.
                                    // I bez jména (`artistId` bez `artistName`,
                                    // starší data) jde aspoň prokliknout.
                                    onTap: nowPlaying.artistId == null
                                        ? null
                                        : () => context.push('/artists/${nowPlaying.artistId}'),
                                    child: Text(
                                    nowPlaying.artistName ?? 'Zobrazit interpreta',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: fg
                                            .withValues(alpha: 0.75),
                                        fontSize: 12,
                                        decoration: nowPlaying.artistId != null
                                            ? TextDecoration.underline
                                            : null,
                                        decorationColor: fg.withValues(alpha: 0.4)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
                              color: isLiked ? Colors.redAccent : fg,
                              size: 22,
                            ),
                            tooltip: isLiked ? 'Odebrat z oblíbených' : 'Přidat do oblíbených',
                            onPressed: () => ref
                                .read(likedSongsControllerProvider.notifier)
                                .toggle(nowPlaying.recordingId),
                          ),
                          IconButton(
                            icon: playback.isBuffering
                                ? SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: isProvisioning && provisioningPct != null
                                        ? CircularProgressIndicator(strokeWidth: 2, color: fg, value: provisioningPct / 100)
                                        : ExpressiveLoadingIndicator(size: 24, color: fg),
                                  )
                                : hasError
                                    ? const Icon(Symbols.refresh_rounded, color: Colors.redAccent, size: 32)
                                    : Icon(
                                        playback.isPlaying
                                            ? Symbols.pause_circle_rounded
                                            : Symbols.play_circle_rounded,
                                        color: fg,
                                        size: 38,
                                      ),
                            tooltip: hasError ? 'Zkusit znovu' : null,
                            onPressed: playback.isBuffering
                                ? null
                                : hasError
                                    ? retry
                                    : () => ref
                                        .read(audioPlayerControllerProvider.notifier)
                                        .togglePlayPause(),
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
    );
      },
    );
  }
}
