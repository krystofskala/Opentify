import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/audio_player_controller.dart';
import '../state/liked_songs_controller.dart';
import '../state/provisioning_controller.dart';
import '../theme/accent_color.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart';
import 'glass_container.dart';
import 'wavy_seek_bar.dart';

/// Perzistentní "Liquid Glass" lišta přehrávače -- rozostřený obal alba na
/// pozadí, přes něj poloprůhledná skleněná vrstva (`BackdropFilter`). Vkládá
/// se do `bottomNavigationBar` slotu na každé obrazovce, kde má být vidět
/// (viz `HomeShell`, `ReleaseScreen`, `ArtistScreen`). Když nic nehraje,
/// nezabírá žádné místo.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

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
      builder: (context, accent) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ClipRRect(
        // Vnější `ClipRRect` zaobluje i obal na pozadí (`GlassContainer` sám
        // zaobluje jen sebe, ne sourozence před sebou ve stejném `Stack`u) --
        // `GlassContainer` samotný teď nese blur+sytost+okraj+highlight,
        // stejné jako Release/Artist hlavičky a Profilovy karty, místo
        // vlastní kopie stejné logiky jen s jiným gradientem.
        borderRadius: BorderRadius.circular(AppRadii.xl),
        child: Stack(
          children: [
            if (nowPlaying.artworkUrl != null)
              Positioned.fill(
                child: CachedNetworkImage(
                    imageUrl: nowPlaying.artworkUrl!, fit: BoxFit.cover),
              )
            else
              Positioned.fill(child: Container(color: accent)),
            GlassContainer(
              borderRadius: BorderRadius.circular(AppRadii.xl),
              blurSigma: GlassTokens.blurLight,
              tint: accent,
              child: SafeArea(
                top: false,
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
                    padding: const EdgeInsets.symmetric(horizontal: 4),
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
                            activeColor: Colors.white,
                            inactiveColor: Colors.white.withValues(alpha: 0.3),
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
                                  ? CachedNetworkImage(
                                      imageUrl: nowPlaying.artworkUrl!,
                                      fit: BoxFit.cover)
                                  : Container(
                                      color:
                                          Colors.white.withValues(alpha: 0.15),
                                      child: const Icon(Symbols.music_note_rounded,
                                          color: Colors.white, size: 20),
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
                                    style: const TextStyle(
                                        color: Colors.white,
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
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12),
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
                                        color: Colors.white
                                            .withValues(alpha: 0.75),
                                        fontSize: 12,
                                        decoration: nowPlaying.artistId != null
                                            ? TextDecoration.underline
                                            : null,
                                        decorationColor: Colors.white.withValues(alpha: 0.4)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isLiked ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
                              color: isLiked ? Colors.redAccent : Colors.white,
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
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                        value: isProvisioning && provisioningPct != null
                                            ? provisioningPct / 100
                                            : null),
                                  )
                                : hasError
                                    ? const Icon(Symbols.refresh_rounded, color: Colors.redAccent, size: 32)
                                    : Icon(
                                        playback.isPlaying
                                            ? Symbols.pause_circle_rounded
                                            : Symbols.play_circle_rounded,
                                        color: Colors.white,
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
          ],
        ),
      ),
    ),
    );
  }
}
