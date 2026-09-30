import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/accent_color.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_tokens.dart' show Expressive, Motion;
import '../state/audio_player_controller.dart';
import '../state/glass_settings.dart';
import '../state/user_idle.dart';
import '../theme/selected_accent.dart';
import 'glass/expressive_shapes.dart';
import 'glass_container.dart';
import 'net_image.dart';
import '../core/cz_plural.dart';

/// Dopočítá barvu nálady obrázku detailové obrazovky a zapíše ji do
/// `screenAccentStackProvider` (globální seed + gradient pozadí) po dobu, co
/// je obrazovka otevřená. Sdílené pro Album/Interpret/Playlist.
class ScreenAccent extends ConsumerStatefulWidget {
  const ScreenAccent({super.key, required this.imageUrl, required this.builder, this.color});

  final String? imageUrl;

  /// Pevná barva obrazovky místo barvy z obrázku (generativní obal
  /// vlastního mixu -- barva stránky má odpovídat obalu, ne fotce první
  /// skladby).
  final Color? color;
  final Widget Function(BuildContext context, Color? accent) builder;

  @override
  ConsumerState<ScreenAccent> createState() => _ScreenAccentState();
}

class _ScreenAccentState extends ConsumerState<ScreenAccent> {
  final Object _owner = Object();
  late final ScreenAccentStack _stack;
  late final ScreenImageStack _images;

  @override
  void initState() {
    super.initState();
    // Tady, ne líně až v `dispose` -- tam už `ref` použít nejde.
    _stack = ref.read(screenAccentStackProvider.notifier);
    _images = ref.read(screenImageStackProvider.notifier);
  }

  @override
  void dispose() {
    // Až po snímku -- `dispose` běží uprostřed stavby stromu a změna
    // providera, který `app.dart` sleduje, by v ní vyhodila výjimku.
    final stack = _stack;
    final images = _images;
    final owner = _owner;
    Future.microtask(() {
      images.remove(owner);
      stack.remove(owner);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fixed = widget.color;
    final url = fixed != null ? null : widget.imageUrl;
    final accent = fixed ??
        (url == null ? null : (ref.watch(screenAccentColorProvider(url)).valueOrNull ?? cachedAccentColor(url)));
    // Zapisuje se, až když je barva známá -- do té doby zůstává platná
    // barva předchozí obrazovky (žádné probliknutí přes výchozí fialovou).
    if (accent != null) {
      Future.microtask(() {
        if (!mounted) return;
        // Obrázek dřív než barva -- `EffectiveAccent` pak přečte dvojici
        // barva + obrázek stejné obrazovky (doplňkové tóny obalu). Pevná
        // barva obrázek nemá -- doplňkové tóny se dopočítají z barvy.
        if (url != null) {
          _images.set(_owner, url);
        } else {
          _images.remove(_owner);
        }
        _stack.set(_owner, accent);
      });
    }
    // Hraje-li skladba, tónuje hlavičku její barva (vyhrává všude, viz
    // `effectiveAccentProvider`); vlastní barva obrazovky jen bez přehrávání.
    final playing = ref.watch(trackIsPlayingProvider);
    return widget.builder(context, playing ? (ref.watch(effectiveAccentProvider) ?? accent) : accent);
  }
}

/// Akce v pravém horním rohu hlavičky (skleněný kroužek).
class HeroAction {
  const HeroAction({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

/// Jednotná hlavička VŠECH detailů (Interpret, Album, Playlist, Oblíbené):
/// obrázek přes celou šířku až pod status bar, dole plynule prolnutý do
/// pozadí appky, velký název + podtitulek dole vlevo. Jediný zdroj pravdy
/// pro rozměry, typografii i chování při scrollu:
///
///   * přetažení dolů (iOS bounce) -> obrázek se roztáhne, ukotvený nahoře;
///   * scroll nahoru -> obrázek jede ~0.45× rychlostí (parallax) a tmavne,
///     velký název odjede a zmizí;
///   * u horního okraje se teprve objeví skleněná lišta s malým názvem
///     (glass_tokens: sklo jen pro plovoucí navigaci) -- do té doby jen
///     plovoucí kroužky zpět/akcí;
///   * vše oříznuté na obdélník hlavičky, nic nepřetéká pod obsah.
///
/// Obrázek: `bannerImageUrl` (široká fotka interpreta) > `mosaicUrls` (2×2,
/// playlisty) > `imageUrl` (obal/fotka) > rozostřený `bannerFallbackUrl` >
/// tónovaný gradient s `placeholderIcon`.
///
/// Informační blok dole (stejná skladba na všech detailech):
///   typový štítek (`eyebrow` + `eyebrowIcon`, sjednocená "vybraná" pilulka)
///   -> velký název (max 2 řádky, sám se zmenší) -> `subtitle` (odkaz na
///   interpreta, popis mixu...) -> řádek `meta` s ikonkami. Volitelně
///   `thumbnailUrl` vlevo od názvu (avatar interpreta nad jeho bannerem),
///   ten se při sbalení objeví i malý v liště vedle názvu.
class DetailHeroAppBar extends StatelessWidget {
  const DetailHeroAppBar({
    super.key,
    required this.title,
    this.imageUrl,
    this.accent,
    this.eyebrow,
    this.eyebrowIcon,
    this.subtitle = const [],
    this.meta = const [],
    this.thumbnailUrl,
    this.thumbnailCircle = false,
    this.placeholderIcon = Symbols.album_rounded,
    this.actions = const [],
    this.bannerImageUrl,
    this.bannerFallbackUrl,
    this.mosaicUrls = const [],
    this.artwork,
    this.artworkBackdrop,
  });

  final String title;
  final String? imageUrl;
  final Color? accent;
  final String? eyebrow;
  final IconData? eyebrowIcon;
  final List<Widget> subtitle;
  final List<HeroMetaItem> meta;
  final String? thumbnailUrl;
  final bool thumbnailCircle;
  final IconData placeholderIcon;
  final List<HeroAction> actions;
  final String? bannerImageUrl;
  final String? bannerFallbackUrl;
  final List<String> mosaicUrls;

  /// Vlastní obal místo obrázku (generativní obal vlastních mixů) -- velký
  /// čtverec na širokém okně, přes celou hlavičku na úzkém.
  final Widget? artwork;

  /// Varianta [artwork] přes celou hlavičku na úzkém okně (bez nápisů --
  /// název je v hlavičce zvlášť).
  final Widget? artworkBackdrop;

  /// Výška roztažené hlavičky bez status baru -- stejná na všech detailech.
  static double expandedHeightFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (isWide(context)) return _wideCoverSize(width) + 2 * _wideBoxPadding + kToolbarHeight + AppSpacing.lg;
    // O ~15 % nižší než dřív -- živé pozadí je vidět dřív (schválený plán
    // hlavičky; fotka zůstává, ambientně se rozplývá, viz `_AmbientFade`).
    return (width * 0.77).clamp(290.0, 400.0);
  }

  /// Široké okno (desktop/tablet na šířku): místo fotky přes celou šířku
  /// (roztažená fotka na 2000 px nikdy nevypadá dobře) rozostřený tónovaný
  /// pás + M3 Expressive kompozice (obal na hravých tvarech) a informační blok,
  /// vše v obsahovém sloupci [kDetailMaxWidth].
  static bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 840;

  static double _wideCoverSize(double width) => width >= 1200 ? 260 : 220;
  static const double _wideBoxPadding = 24;

  /// Bez fotky/obalu -- hlavička je jen náš symbol (Oblíbené, Poslechnout
  /// později...). Na telefonu se pak kreslí jen ikona bez barevné plochy a
  /// přes celou výšku prosvítá živé pozadí appky.
  bool get _iconOnly =>
      artwork == null &&
      artworkBackdrop == null &&
      bannerImageUrl == null &&
      imageUrl == null &&
      mosaicUrls.isEmpty &&
      bannerFallbackUrl == null;

  /// Malý obrázek do sbalené lišty.
  String? get _barThumb =>
      thumbnailUrl ?? imageUrl ?? (mosaicUrls.isNotEmpty ? mosaicUrls.first : null) ?? bannerFallbackUrl;

  @override
  Widget build(BuildContext context) {
    final expanded = expandedHeightFor(context);
    final canPop = Navigator.of(context).canPop();
    final wide = isWide(context);
    // Na širokém okně i ovládání lišty drží okraje obsahového sloupce.
    final side = wide ? detailSideInset(context) : 0.0;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: expanded,
      automaticallyImplyLeading: false,
      forceMaterialTransparency: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      leadingWidth: kToolbarHeight + side,
      leading: canPop
          ? Padding(
              padding: EdgeInsets.only(left: side),
              child: Center(
                child: _HeroCircleButton(
                  icon: Symbols.arrow_back_rounded,
                  tooltip: 'Zpět',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            )
          : null,
      actions: [
        for (final action in actions)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: _HeroCircleButton(icon: action.icon, tooltip: action.tooltip, onPressed: action.onPressed),
          ),
        SizedBox(width: AppSpacing.xs + side),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) => _HeroFlexible(
          hero: this,
          height: constraints.maxHeight,
          expanded: expanded,
          leadingWidth: (canPop ? kToolbarHeight : AppSpacing.md) + side,
          trailingInset: AppSpacing.md + actions.length * 48.0 + side,
          wide: wide,
          side: side,
        ),
      ),
    );
  }
}

/// Max. šířka obsahového sloupce detailů na širokém okně (hlavička i seznamy).
const kDetailMaxWidth = 1160.0;

/// Boční odsazení, které sloupec [kDetailMaxWidth] vycentruje (na telefonu 0).
double detailSideInset(BuildContext context) => math.max(0.0, (MediaQuery.sizeOf(context).width - kDetailMaxWidth) / 2);

/// Obalí slivery obsahu detailu (vše pod hlavičkou) tak, aby na širokém
/// okně ležely ve vycentrovaném sloupci [kDetailMaxWidth] -- scrolluje se
/// ale pořád celou šířkou okna (kolečko myši funguje i nad okraji).
List<Widget> detailContentSlivers(BuildContext context, List<Widget> slivers) {
  final side = detailSideInset(context);
  if (side == 0) return slivers;
  return [
    for (final sliver in slivers) SliverPadding(padding: EdgeInsets.symmetric(horizontal: side), sliver: sliver),
  ];
}

class _HeroFlexible extends StatelessWidget {
  const _HeroFlexible({
    required this.hero,
    required this.height,
    required this.expanded,
    required this.leadingWidth,
    required this.trailingInset,
    required this.wide,
    required this.side,
  });

  final DetailHeroAppBar hero;
  final double height;
  final double expanded;
  final double leadingWidth;
  final double trailingInset;
  final bool wide;
  final double side;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final maxH = expanded + top;
    final minH = kToolbarHeight + top;

    final stretch = math.max(0.0, height - maxH);
    // 0 = roztaženo, 1 = sbaleno.
    final collapse = ((maxH - height) / (maxH - minH)).clamp(0.0, 1.0);
    // Parallax: obrázek se posouvá pomaleji než obsah; při přetažení dolů
    // naopak roste a zůstává ukotvený nahoře.
    final imageTop = stretch > 0 ? 0.0 : -(maxH - height) * 0.45;
    final imageHeight = stretch > 0 ? height : maxH;

    // Velký název mizí v první ~polovině sbalování, lišta se skleněným
    // pozadím a malým názvem se objeví až u horního okraje.
    final titleT = (1 - collapse / 0.55).clamp(0.0, 1.0);
    final barT = ((collapse - 0.72) / 0.28).clamp(0.0, 1.0);
    final iconOnly = hero._iconOnly && !wide;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Široké okno: žádný pás s rozmazanou fotkou -- jeho barvy se bily
          // s pozadím v barvě hrající skladby (živě nahlášeno). Obal s tvary
          // leží přímo na živém pozadí appky.
          if (!wide)
            // Prolnutí do pozadí vždy k AKTUÁLNÍ spodní hraně hlavičky -- při
            // částečném sbalení jinak obrázek končil ostrou hranou nad seznamem.
            // Končí 2 px nad spodní hranou a maska je průhledná už od 94 % --
            // na iPhonu (zlomkové pixely) jinak poslední řádek fotky vyklouzl
            // masce a nad popiskem problikávala tenká čára (živě nahlášeno).
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 2,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black, Colors.black, Color(0x00000000), Color(0x00000000)],
                  stops: [0, 0.42, 0.94, 1],
                ).createShader(rect),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      top: imageTop,
                      left: 0,
                      right: 0,
                      height: imageHeight,
                      child: _AmbientFade(
                        enabled: !iconOnly,
                        child: _FadedMedia(hero: hero, darken: iconOnly ? 0 : collapse * 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Ztmavení pod status barem a kroužky -- čitelnost na světlých fotkách.
          if (!iconOnly)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: top + kToolbarHeight + 24,
              child: const _AmbientFade(
                enabled: true,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x66000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Závoj pod informačním blokem v barvě plochy -- text `onSurface`
          // je čitelný nad jakoukoliv fotkou, v tmavém i světlém režimu.
          if (titleT > 0 && !wide && !iconOnly)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height * 0.62,
              child: _AmbientFade(
                enabled: true,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: titleT,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          // Dole zase do nuly -- jinak by na hraně hlavičky
                          // vznikl ostrý tmavý předěl proti pozadí seznamu.
                          colors: [
                            theme.colorScheme.surface.withValues(alpha: 0),
                            theme.colorScheme.surface.withValues(alpha: 0.45),
                            theme.colorScheme.surface.withValues(alpha: 0.4),
                            theme.colorScheme.surface.withValues(alpha: 0),
                          ],
                          stops: const [0, 0.42, 0.78, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (barT > 0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height,
              child: Opacity(
                opacity: barT,
                child: const GlassContainer(
                  borderRadius: BorderRadius.zero,
                  showEdgeHighlight: false,
                  fit: StackFit.expand,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          if (titleT > 0 && !wide)
            Positioned(
              left: AppSpacing.md,
              right: AppSpacing.md,
              bottom: AppSpacing.sm,
              child: Opacity(
                opacity: titleT,
                child: Transform.translate(
                  offset: Offset(0, collapse * 28),
                  child: _HeroTitleBlock(hero: hero),
                ),
              ),
            ),
          if (titleT > 0 && wide)
            Positioned(
              left: side + AppSpacing.md,
              right: side + AppSpacing.md,
              bottom: AppSpacing.lg,
              child: Opacity(
                opacity: titleT,
                child: Transform.translate(
                  offset: Offset(0, collapse * 28),
                  child: _WideHeroBox(hero: hero),
                ),
              ),
            ),
          if (barT > 0)
            Positioned(
              top: top,
              left: leadingWidth + AppSpacing.xs,
              right: trailingInset,
              height: kToolbarHeight,
              child: Opacity(
                opacity: barT,
                child: Transform.translate(
                  offset: Offset(0, (1 - barT) * 10),
                  child: Row(
                    children: [
                      if (hero._barThumb != null) ...[
                        _Thumb(
                          url: hero._barThumb!,
                          size: 30,
                          circle: hero.thumbnailCircle,
                          icon: hero.placeholderIcon,
                          seed: hero.title,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      Expanded(
                        child: Text(
                          hero.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Ambientní" hlavička: ~5 s bez doteku při přehrávání (~10 s bez hudby) se fotka
/// pomalu rozplyne do živého pozadí (zůstane jen slabá stopa), dotek ji
/// hned vrátí. Rozvržení se nehýbe -- mizí jen obraz, ne místo.
class _AmbientFade extends ConsumerWidget {
  const _AmbientFade({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  static const _trace = 0.14;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!enabled) return child;
    // S hudbou po ~5 s, bez ní po ~10 s (stránku si nejspíš prohlížíš).
    final playing = ref.watch(audioPlayerControllerProvider.select((s) => s.isPlaying));
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return ValueListenableBuilder<bool>(
      valueListenable: playing ? UserIdle.idle : UserIdle.idleLong,
      builder: (context, idle, child) {
        final target = idle ? _trace : 1.0;
        return TweenAnimationBuilder<double>(
          tween: Tween(end: target),
          // Výjimka z `Motion` (vlastní ambientní tempo, ne odezva na akci):
          // pryč pomalu (rozplynutí), zpátky plynulým prolnutím -- ne skokem
          // (živě: "nesmí se objevit hned").
          duration: reduceMotion
              ? Duration.zero
              : (idle ? const Duration(milliseconds: 2200) : const Duration(milliseconds: 700)),
          curve: Curves.easeInOutCubic,
          builder: (context, v, child) => v >= 0.999 ? child! : Opacity(opacity: v, child: child),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// Obrázek hlavičky, dole maskou prolnutý do průhledna (prosvítá pozadí
/// appky) a volitelně ztmavený (při sbalování).
class _FadedMedia extends StatelessWidget {
  const _FadedMedia({required this.hero, required this.darken});

  final DetailHeroAppBar hero;
  final double darken;

  @override
  Widget build(BuildContext context) {
    // Maska prolnutí je o úroveň výš (`_HeroFlexible`) -- podle viditelné výšky.
    return Stack(
      fit: StackFit.expand,
      children: [
        _media(context),
        if (darken > 0.001) IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: darken))),
      ],
    );
  }

  Widget _media(BuildContext context) {
    if ((hero.artworkBackdrop ?? hero.artwork) case final art?) return art;
    final mosaic = hero.mosaicUrls.toSet().toList();
    if (hero.bannerImageUrl != null) {
      return _WideAware(
        url: hero.bannerImageUrl!,
        alignment: const Alignment(0, -0.3),
        accent: hero.accent,
        icon: hero.placeholderIcon,
      );
    }
    if (mosaic.length >= 4) return _Mosaic(urls: mosaic.take(4).toList());
    final single = hero.imageUrl ?? (mosaic.isNotEmpty ? mosaic.first : null);
    if (single != null) {
      return _WideAware(
          url: single, alignment: const Alignment(0, -0.4), accent: hero.accent, icon: hero.placeholderIcon);
    }
    if (hero.bannerFallbackUrl != null) return _Blurred(url: hero.bannerFallbackUrl!, accent: hero.accent);
    return _GradientArt(icon: hero.placeholderIcon, accent: hero.accent, bare: true);
  }
}

/// Široké okno: M3 Expressive kompozice přímo na živém pozadí (bez
/// skleněného boxu) -- velký obal/fotka (kruh u interpreta) na hravých
/// tvarech se zrnitým gradientem v barvě stránky, informační blok vpravo.
class _WideHeroBox extends StatefulWidget {
  const _WideHeroBox({required this.hero});

  final DetailHeroAppBar hero;

  @override
  State<_WideHeroBox> createState() => _WideHeroBoxState();
}

/// Příchod interpreta: fotka se z kruhu přelije do svého tvaru a samolepky
/// postupně "vyskočí" (M3 Expressive pružiny). Při "omezit pohyb" hned hotovo.
class _WideHeroBoxState extends State<_WideHeroBox> with SingleTickerProviderStateMixin {
  late final AnimationController _intro =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  static final Set<String> _played = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_intro.isAnimating || _intro.value > 0) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Jen při prvním příchodu na interpreta -- hlavička se při scrollu
    // odebírá a znovu přidává, animace by se jinak opakovala.
    if (!widget.hero.thumbnailCircle || reduceMotion || !_played.add(widget.hero.title)) {
      _intro.value = 1;
    } else {
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  /// Úsek celkové animace [from, to] přemapovaný na 0..1 a prohnaný pružinou.
  double _phase(double from, double to, Curve curve) {
    final v = ((_intro.value - from) / (to - from)).clamp(0.0, 1.0);
    return curve.transform(v);
  }

  @override
  Widget build(BuildContext context) {
    final hero = widget.hero;
    final cover = DetailHeroAppBar._wideCoverSize(MediaQuery.sizeOf(context).width);
    // Samolepky jen u interpreta (fotka ve tvaru je naše kompozice). Obal
    // alba je sám o sobě dílo -- tvar přes něj by ho jen zakryl.
    final look = hero.thumbnailCircle ? _ArtistLook.of(hero.title) : null;
    final accent = hero.accent ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(DetailHeroAppBar._wideBoxPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox.square(
            dimension: cover,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: _intro,
                  builder: (context, _) {
                    final morph = _phase(0, 0.6, Motion.enter);
                    return Transform.scale(
                      scale: 0.9 + 0.1 * morph,
                      child: _WideCover(hero: hero, size: cover, look: look, morph: morph),
                    );
                  },
                ),
                // Malé "samolepky" kolem fotky (schválená varianta C) -- každý
                // interpret jiný tvar, místo a velikost, u jednoho vždy stejné.
                if (look != null)
                  for (final (i, s) in look.stickers.indexed)
                    Positioned(
                      left: cover * s.x,
                      top: cover * s.y,
                      width: cover * s.size,
                      height: cover * s.size,
                      child: AnimatedBuilder(
                        animation: _intro,
                        builder: (context, child) {
                          final pop = _phase(0.35 + i * 0.15, 0.85 + i * 0.15, Motion.press);
                          return Transform.rotate(
                            angle: (1 - pop) * -0.9,
                            child: Transform.scale(scale: pop.clamp(0.0, 1.3), child: child),
                          );
                        },
                        child: RepaintBoundary(
                          child: AnimatedAccent(
                            color: accent,
                            builder: (context, c) =>
                                CustomPaint(painter: _StickerPainter(c, s.shape, s.hueShift, s.spin)),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xl + AppSpacing.md),
          Expanded(child: _HeroTitleBlock(hero: hero, showThumb: false)),
        ],
      ),
    );
  }
}

/// Malý čtyřlístek se zrnitým gradientem v barvě stránky (u černobílé
/// stránky zůstane šedý).
class _StickerPainter extends CustomPainter {
  const _StickerPainter(this.accent, this.shape, this.hueShift, this.spin);

  final Color accent;
  final ExpressiveShape shape;
  final double hueShift;
  final double spin;

  Color _tone(double hueShift, double lightness) {
    final hsl = HSLColor.fromColor(accent);
    return hsl
        .withHue((hsl.hue + hueShift) % 360)
        .withSaturation(math.min(hsl.saturation, 0.7))
        .withLightness(lightness)
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = expressivePath(rect, shape, null, 0, spin);
    canvas.drawShadow(path, Colors.black, 6, false);
    paintGrainShape(canvas, path, rect, 0, from: _tone(hueShift, 0.76), to: _tone(hueShift + 30, 0.52));
  }

  @override
  bool shouldRepaint(covariant _StickerPainter old) =>
      old.accent != accent || old.shape != shape || old.hueShift != hueShift || old.spin != spin;
}

class _Sticker {
  const _Sticker(this.x, this.y, this.size, this.shape, this.hueShift, this.spin);

  /// Levý horní roh a velikost v násobcích velikosti fotky.
  final double x;
  final double y;
  final double size;
  final ExpressiveShape shape;
  final double hueShift;
  final double spin;
}

/// Vzhled hlavičky interpreta odvozený z jeho jména: tvar fotky a rozmístění
/// samolepek. Stálý pro interpreta, různý mezi interprety.
class _ArtistLook {
  const _ArtistLook(this.photo, this.photoSpin, this.stickers);

  final ExpressiveShape photo;
  final double photoSpin;
  final List<_Sticker> stickers;

  /// Tvary, které snesou obličej (bez hlubokých zářezů).
  static const _photoShapes = [
    ExpressiveShape.cookie(lobes: 12, depth: 0.06),
    ExpressiveShape.cookie(lobes: 9, depth: 0.08),
    ExpressiveShape.cookie(lobes: 7, depth: 0.09),
    ExpressiveShape.cookie(lobes: 6, depth: 0.1),
    ExpressiveShape.cookie(lobes: 4, depth: 0.12),
    ExpressiveShape.squircle(squareness: 0.85),
  ];

  static const _stickerShapes = [
    ExpressiveShape.cookie(lobes: 4, depth: 0.22),
    ExpressiveShape.cookie(lobes: 9, depth: 0.1),
    ExpressiveShape.cookie(lobes: 5, depth: 0.26),
    ExpressiveShape.circle(),
  ];

  /// Místa (x, y) samolepky kolem fotky -- vždy přes okraj, nikdy přes střed.
  static const _spots = [
    (0.79, -0.03), // vpravo nahoře
    (-0.08, 0.70), // vlevo dole
    (0.80, 0.68), // vpravo dole
    (-0.06, 0.02), // vlevo nahoře
    (0.62, 0.84), // dole vpravo od středu
  ];

  static _ArtistLook of(String seedText) {
    final rnd = math.Random(seedText.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff));
    final photo = _photoShapes[rnd.nextInt(_photoShapes.length)];
    final spots = [..._spots]..shuffle(rnd);
    final main = _Sticker(
      spots[0].$1,
      spots[0].$2,
      0.22 + rnd.nextDouble() * 0.1,
      _stickerShapes[rnd.nextInt(_stickerShapes.length)],
      -40 + rnd.nextDouble() * 80,
      rnd.nextDouble() * math.pi,
    );
    // Někdy ještě malá tečka jinde -- ne u všech, ať to není šablona.
    final extra = rnd.nextDouble() < 0.45
        ? [
            _Sticker(spots[1].$1 + 0.04, spots[1].$2 + 0.04, 0.09, const ExpressiveShape.circle(),
                120 + rnd.nextDouble() * 60, 0),
          ]
        : const <_Sticker>[];
    return _ArtistLook(photo, rnd.nextDouble() * math.pi, [main, ...extra]);
  }
}

/// Obal/fotka na širokém okně. Interpret: fotka vystřižená do M3 Expressive
/// "cookie" (výrazný avatar); album/playlist: zaoblený čtverec -- cookie by
/// ořízl rohy obalu (text, logo).
class _WideCover extends StatelessWidget {
  const _WideCover({required this.hero, required this.size, this.look, this.morph = 1});

  final DetailHeroAppBar hero;
  final double size;
  final _ArtistLook? look;

  /// 0 = kruh, 1 = tvar interpreta (příchodová animace).
  final double morph;

  @override
  Widget build(BuildContext context) {
    final mosaic = hero.mosaicUrls.toSet().toList();
    final url = hero.thumbnailUrl ?? hero.imageUrl ?? (mosaic.isNotEmpty ? mosaic.first : null);
    final Widget child;
    if (hero.artwork != null) {
      child = hero.artwork!;
    } else if (hero.thumbnailUrl == null && hero.imageUrl == null && mosaic.length >= 4) {
      child = _Mosaic(urls: mosaic.take(4).toList());
    } else if (url != null) {
      child = NetImage(url: url, placeholder: _GradientArt(icon: hero.placeholderIcon, accent: hero.accent));
    } else {
      child = _GradientArt(icon: hero.placeholderIcon, accent: hero.accent);
    }
    if (hero.thumbnailCircle) {
      final l = look ?? _ArtistLook.of(hero.title);
      final path = expressivePath(
        Offset.zero & Size.square(size),
        const ExpressiveShape.circle(),
        l.photo,
        morph,
        l.photoSpin,
      );
      return SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _PathShadowPainter(path),
          child: ClipPath(clipper: _PathClipper(path), child: SizedBox.expand(child: child)),
        ),
      );
    }
    final radius = BorderRadius.circular(Expressive.cornerExtraLarge);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 28, offset: const Offset(0, 10))
        ],
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}

class _PathClipper extends CustomClipper<Path> {
  const _PathClipper(this.path);
  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(covariant _PathClipper old) => old.path != path;
}

class _PathShadowPainter extends CustomPainter {
  const _PathShadowPainter(this.path);
  final Path path;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawShadow(path.shift(const Offset(0, 6)), Colors.black, 14, false);

  @override
  bool shouldRepaint(covariant _PathShadowPainter old) => old.path != path;
}

/// Na telefonu přes celou šířku; na širokém okně (poměr nad ~1.8:1) by
/// `BoxFit.cover` ze čtvercového obalu/fotky ukázal jen úzký pruh a uřízl
/// hlavy -- tam zůstane obrázek uprostřed v rozumném poměru a boky vyplní
/// jeho rozostřená verze.
class _WideAware extends StatelessWidget {
  const _WideAware({required this.url, required this.alignment, required this.accent, required this.icon});

  final String url;
  final Alignment alignment;
  final Color? accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Než se obrázek stáhne (Cover Art Archive trvá i sekundy) nebo když
        // selže: tónovaný gradient, ne prázdná díra nahoře.
        final image = NetImage(url: url, alignment: alignment, placeholder: _GradientArt(icon: icon, accent: accent));
        const maxAspect = 1.8;
        if (constraints.maxWidth <= constraints.maxHeight * maxAspect) return image;
        return Stack(
          fit: StackFit.expand,
          children: [
            _Blurred(url: url, accent: accent),
            Center(
              child: SizedBox(
                width: constraints.maxHeight * maxAspect,
                height: constraints.maxHeight,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    colors: [Color(0x00000000), Colors.black, Colors.black, Color(0x00000000)],
                    stops: [0, 0.12, 0.88, 1],
                  ).createShader(rect),
                  child: image,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Blurred extends StatelessWidget {
  const _Blurred({required this.url, required this.accent});

  final String url;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28, tileMode: TileMode.mirror),
            child: NetImage(url: url),
          ),
          AnimatedAccent(
            color: accent ?? Colors.black,
            builder: (context, c) => ColoredBox(color: c.withValues(alpha: 0.25)),
          ),
        ],
      ),
    );
  }
}

class _Mosaic extends StatelessWidget {
  const _Mosaic({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    Widget cell(String url) => Expanded(child: NetImage(url: url));
    return Column(
      children: [
        Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [cell(urls[0]), cell(urls[1])])),
        Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [cell(urls[2]), cell(urls[3])])),
      ],
    );
  }
}

/// Bez obrázku (Oblíbené, prázdný playlist): tónovaný gradient s velkou
/// ikonou -- navržená plocha, ne šedý placeholder.
class _GradientArt extends StatelessWidget {
  const _GradientArt({required this.icon, required this.accent, this.bare = false});

  final IconData icon;
  final Color? accent;

  /// Jen ikona, bez barevné plochy (hlavička bez obrázku na telefonu).
  final bool bare;

  @override
  Widget build(BuildContext context) {
    if (bare) {
      return Align(
        alignment: const Alignment(0.55, -0.15),
        child: Icon(
          icon,
          size: 132,
          fill: 1,
          color: Colors.white.withValues(alpha: 0.92),
          shadows: [Shadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 32, offset: const Offset(0, 10))],
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final base = accent ?? scheme.primary;
    final hsl = HSLColor.fromColor(base);
    final deep = hsl.withLightness((hsl.lightness * 0.55).clamp(0.12, 0.4)).toColor();
    // Šedý seed bez odstínu nechat šedý (odstín 0° = červená).
    final bright = isAchromatic(base)
        ? hsl.withLightness(0.62).toColor()
        : hsl.withHue((hsl.hue + 35) % 360).withLightness(0.62).withSaturation(0.7).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bright, base, deep],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: Align(
        alignment: const Alignment(0.55, -0.15),
        child: Icon(icon, size: 132, fill: 1, color: Colors.white.withValues(alpha: 0.9)),
      ),
    );
  }
}

class _HeroTitleBlock extends StatelessWidget {
  const _HeroTitleBlock({required this.hero, this.showThumb = true});

  final DetailHeroAppBar hero;

  /// `false` ve širokém boxu -- velký obal tam stojí samostatně vlevo.
  final bool showThumb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final glow = [Shadow(color: theme.colorScheme.surface.withValues(alpha: 0.6), blurRadius: 16)];
    final titleColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hero.eyebrow != null) ...[
          _TypeChip(label: hero.eyebrow!, icon: hero.eyebrowIcon),
          const SizedBox(height: AppSpacing.xs),
        ],
        _AutoShrinkTitle(
          text: hero.title,
          style: theme.textTheme.displaySmall!.copyWith(
            color: fg,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
            height: 1.02,
            shadows: glow,
          ),
        ),
      ],
    );
    return DefaultTextStyle.merge(
      style: TextStyle(color: fg, shadows: glow),
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showThumb && hero.thumbnailUrl != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _Thumb(
                    url: hero.thumbnailUrl!,
                    size: 84,
                    circle: hero.thumbnailCircle,
                    icon: hero.placeholderIcon,
                    elevated: true,
                    seed: hero.title,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: titleColumn),
                ],
              )
            else
              titleColumn,
            if (hero.subtitle.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              ...hero.subtitle,
            ],
            if (hero.meta.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              HeroMetaRow(items: hero.meta),
            ],
          ],
        ),
      ),
    );
  }
}

/// Typový štítek (ALBUM, INTERPRET, DENNÍ MIX...) -- sjednocená "vybraná"
/// pilulka z glass_tokens: `primaryContainer` + vnitřní horní lesk, text a
/// ikona `onPrimaryContainer`.
class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onPrimaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [
            Color.alphaBlend(
              Colors.white.withValues(alpha: Expressive.selectedPillHighlightAlpha),
              scheme.primaryContainer,
            ),
            scheme.primaryContainer,
          ],
        ),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(icon != null ? 8 : 10, 4, 10, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, fill: 1, color: fg),
              const SizedBox(width: 4),
            ],
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: fg,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                height: 1.2,
                shadows: const [],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Velký název: max 2 řádky; když se nevejde, postupně se zmenšuje
/// (displaySmall -> ~28 px), teprve pak trojtečka.
class _AutoShrinkTitle extends StatelessWidget {
  const _AutoShrinkTitle({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final base = style.fontSize ?? 36;
        var size = base + 6;
        for (; size > 26; size -= 2) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style.copyWith(fontSize: size)),
            maxLines: 2,
            textDirection: Directionality.of(context),
            textScaler: scaler,
          )..layout(maxWidth: constraints.maxWidth);
          final fits = !painter.didExceedMaxLines && (painter.computeLineMetrics().length <= 1 || size <= base);
          painter.dispose();
          if (fits) break;
        }
        return Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontSize: size),
        );
      },
    );
  }
}

/// Náhled (obal/avatar) vedle názvu a ve sbalené liště.
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.url,
    required this.size,
    required this.circle,
    required this.icon,
    this.elevated = false,
    this.seed,
  });

  final String url;
  final double size;

  /// Interpret: místo kruhu jeho "fun shape" (stejný jako na PC, podle
  /// jména -- `seed`), bez rámečku.
  final bool circle;
  final IconData icon;
  final bool elevated;
  final String? seed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (circle) {
      final look = _ArtistLook.of(seed ?? url);
      final path = expressivePath(Offset.zero & Size.square(size), look.photo, null, 0, look.photoSpin);
      final image = ClipPath(
        clipper: _PathClipper(path),
        child: ColoredBox(
          color: scheme.surfaceContainerHigh,
          child: NetImage(url: url, placeholder: Icon(icon, size: size * 0.45, color: scheme.onSurfaceVariant)),
        ),
      );
      return SizedBox.square(
        dimension: size,
        child: elevated ? CustomPaint(painter: _PathShadowPainter(path), child: image) : image,
      );
    }
    final radius =
        circle ? BorderRadius.circular(size / 2) : BorderRadius.circular(size >= 64 ? AppRadii.md : AppRadii.xs);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: scheme.surfaceContainerHigh,
        border: elevated ? Border.all(color: Colors.white.withValues(alpha: 0.22), width: 1.5) : null,
        boxShadow: elevated
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: NetImage(
          url: url,
          placeholder: Icon(icon, size: size * 0.45, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Jedna položka řádku metadat pod názvem (ikonka + text). `emphasized`
/// = tónová pilulka (pořadí/odznak žebříčku).
class HeroMetaItem {
  const HeroMetaItem(this.icon, this.text, {this.emphasized = false});

  final IconData icon;
  final String text;
  final bool emphasized;
}

/// Řádek metadat s ikonkami (rok · skladby · délka · aktualizace...) --
/// zalamuje se, nic se neořízne.
class HeroMetaRow extends StatelessWidget {
  const HeroMetaRow({super.key, required this.items});

  final List<HeroMetaItem> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = DefaultTextStyle.of(context).style.color ?? scheme.onSurface;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final item in items)
          if (item.emphasized)
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(item.icon, size: 14, fill: 1, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 3),
                    Text(
                      item.text,
                      style: TextStyle(
                        color: scheme.onSecondaryContainer,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        shadows: const [],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon, size: 15, color: base.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  item.text,
                  style: TextStyle(color: base.withValues(alpha: 0.82), fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
      ],
    );
  }
}

/// Krátká upoutávka (životopis interpreta) hned pod hlavičkou: 2 řádky,
/// klepnutím se plynule rozbalí celá.
class HeroTeaser extends StatefulWidget {
  const HeroTeaser({super.key, required this.text});

  final String text;

  @override
  State<HeroTeaser> createState() => _HeroTeaserState();
}

class _HeroTeaserState extends State<HeroTeaser> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // "Zobrazit vše" jen když text opravdu přesahuje 2 řádky -- dřív byl
          // odkaz i pod krátkým textem a nedělal nic (živě nahlášeno).
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            maxLines: 2,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final overflows = painter.didExceedMaxLines;
          painter.dispose();
          final text = Text(
            widget.text,
            maxLines: _expanded || !overflows ? null : 2,
            overflow: _expanded || !overflows ? TextOverflow.visible : TextOverflow.ellipsis,
            style: style,
          );
          if (!overflows) return text;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: AnimatedSize(
                duration: Motion.enter.duration,
                curve: Motion.enter,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    text,
                    const SizedBox(height: 2),
                    Text(
                      _expanded ? 'Zobrazit méně' : 'Zobrazit vše',
                      style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "42 min" / "5 h 25 min" -- jen když je délka známá aspoň u ~90 % skladeb
/// (jinak by součet lhal); jinak `null`.
String? heroTotalDuration(Iterable<int?> durationsMs) {
  final list = durationsMs.toList();
  if (list.isEmpty) return null;
  final known = list.whereType<int>().toList();
  if (known.length < list.length * 0.9) return null;
  final minutes = (known.fold<int>(0, (a, b) => a + b) / 60000).round();
  if (minutes <= 0) return null;
  return minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${minutes % 60} min';
}

/// "Aktualizováno dnes / včera / 28. 9."
String heroUpdatedLabel(DateTime at) {
  final local = at.toLocal();
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (days <= 0) return 'Aktualizováno dnes';
  if (days == 1) return 'Aktualizováno včera';
  return 'Aktualizováno ${local.day}. ${local.month}.';
}

/// "1 skladba / 3 skladby / 40 skladeb".
String heroTrackCount(int n) => songsCount(n);

/// Plovoucí tlačítko nad obrázkem -- tmavý průsvitný kroužek (čitelný na
/// světlé fotce i na skleněné liště). Bez vlastního rozmazání: leží nad
/// jinou skleněnou vrstvou, dvojitý BackdropFilter by byl drahý.
class _HeroCircleButton extends StatelessWidget {
  const _HeroCircleButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Profil › Vzhled › "Skleněná tlačítka": skleněná kapka -- rozmazání
    // a lom toho, co je pod ní (fotka i pozadí), přirozený odlesk.
    if (GlassSettings.maybeOf(context)?.glassButtons ?? false) {
      return Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onPressed,
          child: GlassContainer(
            borderRadius: BorderRadius.circular(22),
            blurSigma: 12,
            rim: true,
            child: SizedBox.square(dimension: 44, child: Icon(icon, color: Colors.white, size: 22)),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.32),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(dimension: 44, child: Icon(icon, color: Colors.white, size: 22)),
        ),
      ),
    );
  }
}

/// Klikatelný řádek v hlavičce (interpret, album).
class HeroLink extends StatelessWidget {
  const HeroLink({super.key, required this.text, this.onTap, this.icon, this.avatarUrl});

  final String text;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Malý kulatý avatar místo ikonky (fotka interpreta u alba).
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.color ?? Colors.white;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (avatarUrl != null) ...[
          // Malý avatar interpreta v jeho tvaru, bez rámečku (nenásilně).
          _Thumb(url: avatarUrl!, size: 26, circle: true, icon: icon ?? Symbols.person_rounded, seed: text),
          const SizedBox(width: AppSpacing.xs),
        ] else if (icon != null) ...[
          Icon(icon, size: 16, color: base.withValues(alpha: 0.7)),
          const SizedBox(width: AppSpacing.xxs),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: base.withValues(alpha: 0.9),
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        if (onTap != null) Icon(Symbols.chevron_right_rounded, size: 20, color: base.withValues(alpha: 0.6)),
      ],
    );
    if (onTap == null) return child;
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: child));
  }
}

/// Textový řádek pod názvem (popis mixu/žebříčku: "The Doors, The Beatles
/// a další") -- metadata s ikonkami patří do `DetailHeroAppBar.meta`.
class HeroMeta extends StatelessWidget {
  const HeroMeta(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.color ?? Colors.white;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: base.withValues(alpha: 0.88), fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
      ),
    );
  }
}
