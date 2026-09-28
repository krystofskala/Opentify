import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/accent_color.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';
import 'glass_container.dart';
import 'media_card.dart' show ArtworkImage;

/// Dopočítá barvu nálady obrázku detailové obrazovky a zapíše ji do
/// `screenAccentStackProvider` (globální seed + gradient pozadí) po dobu, co
/// je obrazovka otevřená. Sdílené pro Album/Interpret/Skladbu/Playlist --
/// dřív to Release a Artist měly každý po svém (a jen tyhle dva).
class ScreenAccent extends ConsumerStatefulWidget {
  const ScreenAccent({super.key, required this.imageUrl, required this.builder});

  final String? imageUrl;
  final Widget Function(BuildContext context, Color? accent) builder;

  @override
  ConsumerState<ScreenAccent> createState() => _ScreenAccentState();
}

class _ScreenAccentState extends ConsumerState<ScreenAccent> {
  final Object _owner = Object();
  late final ScreenAccentStack _stack;

  @override
  void initState() {
    super.initState();
    // Tady, ne líně až v `dispose` -- tam už `ref` použít nejde.
    _stack = ref.read(screenAccentStackProvider.notifier);
  }

  @override
  void dispose() {
    // Až po snímku -- `dispose` běží uprostřed stavby stromu a změna
    // providera, který `app.dart` sleduje, by v ní vyhodila výjimku.
    final stack = _stack;
    final owner = _owner;
    Future.microtask(() => stack.remove(owner));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl;
    final accent = url == null
        ? null
        : (ref.watch(screenAccentColorProvider(url)).valueOrNull ?? cachedAccentColor(url));
    // Zapisuje se, až když je barva známá -- do té doby zůstává platná
    // barva předchozí obrazovky (žádné probliknutí přes výchozí fialovou,
    // přechod pak jen plynule doanimuje z předchozí barvy na novou).
    if (accent != null) {
      Future.microtask(() {
        if (mounted) _stack.set(_owner, accent);
      });
    }
    return widget.builder(context, accent);
  }
}

/// Sjednocená hlavička detailu (Album, Interpret, Skladba, Playlist):
/// rozostřený obrázek na pozadí tónovaný barvou nálady, skleněná karta s
/// obalem/fotkou, "eyebrow" typem, názvem a podtitulkem. Po sbalení zůstane
/// úzký rozostřený pruh s názvem.
class DetailHeroAppBar extends StatelessWidget {
  const DetailHeroAppBar({
    super.key,
    required this.title,
    this.imageUrl,
    this.accent,
    this.eyebrow,
    this.subtitle = const [],
    this.circleImage = false,
    this.placeholderIcon = Symbols.album_rounded,
    this.actions,
    this.expandedHeight = 300,
    this.banner = false,
    this.bannerFallbackUrl,
  });

  final String title;
  final String? imageUrl;
  final Color? accent;
  final String? eyebrow;
  final List<Widget> subtitle;
  final bool circleImage;
  final IconData placeholderIcon;
  final List<Widget>? actions;
  final double expandedHeight;

  /// Interpret: fotka přes celou šířku (ne rozostřené pozadí + karta),
  /// dole plynule prolnutá do `AppBackground`, jméno velkým písmem přes ni.
  final bool banner;

  /// Když interpret fotku nemá -- rozostřený, přiblížený obal jeho alba,
  /// ať hlavička nikdy není prázdný šedý obdélník.
  final String? bannerFallbackUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final collapsedHeight = kToolbarHeight + topPadding;
    final blurSource = imageUrl ?? bannerFallbackUrl;

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      foregroundColor: Colors.white,
      iconTheme: const IconThemeData(color: Colors.white),
      actions: actions,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final range = (expandedHeight + topPadding) - collapsedHeight;
          final t = range <= 0 ? 0.0 : ((constraints.maxHeight - collapsedHeight) / range).clamp(0.0, 1.0);
          if (banner) return _buildBanner(context, t, blurSource);
          return Stack(
            fit: StackFit.expand,
            children: [
              if (imageUrl != null)
                CachedNetworkImage(imageUrl: imageUrl!, fit: BoxFit.cover)
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [theme.colorScheme.primaryContainer, theme.colorScheme.tertiaryContainer],
                    ),
                  ),
                ),
              ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: ColoredBox(color: (accent ?? Colors.black).withValues(alpha: 0.4)),
                ),
              ),
              // Jemné ztmavení dole, ať bílý text vždy čitelně stojí na
              // světlých obalech.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black26, Colors.transparent, Colors.black38],
                  ),
                ),
              ),
              if (t > 0.05)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Opacity(
                    opacity: t,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                      child: _HeroCard(
                        title: title,
                        imageUrl: imageUrl,
                        eyebrow: eyebrow,
                        subtitle: subtitle,
                        circleImage: circleImage,
                        placeholderIcon: placeholderIcon,
                      ),
                    ),
                  ),
                ),
              if (t < 0.4)
                Positioned(
                  left: 56,
                  right: (actions?.length ?? 0) * 48.0 + AppSpacing.md,
                  bottom: 0,
                  height: kToolbarHeight,
                  child: Opacity(
                    opacity: (1 - t / 0.4).clamp(0.0, 1.0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

extension on DetailHeroAppBar {
  Widget _blurred(BuildContext context, String? url, {double sigma = 40, double dim = 0.4}) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url != null)
          Transform.scale(scale: 1.3, child: CachedNetworkImage(imageUrl: url, fit: BoxFit.cover))
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [theme.colorScheme.primaryContainer, theme.colorScheme.tertiaryContainer],
              ),
            ),
          ),
        ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: ColoredBox(color: (accent ?? Colors.black).withValues(alpha: dim)),
          ),
        ),
      ],
    );
  }

  /// Fotky interpretů jsou většinou čtvercové -- přes celou šířku širokého
  /// okna by `BoxFit.cover` ukázal jen úzký vodorovný pruh a uřízl hlavy.
  /// Nad poměrem ~1.8:1 proto fotka zůstane na středu v rozumném poměru a
  /// boky vyplní její rozostřená verze (na telefonu se nic nemění).
  Widget _bannerPhoto(BuildContext context, String url) {
    const maxAspect = 1.8;
    return LayoutBuilder(
      builder: (context, constraints) {
        final photo = CachedNetworkImage(imageUrl: url, fit: BoxFit.cover, alignment: const Alignment(0, -0.6));
        if (constraints.maxWidth <= constraints.maxHeight * maxAspect) return photo;
        return Stack(
          fit: StackFit.expand,
          children: [
            // `_blurred` zvětšuje obrázek 1.3× -- bez ořezu by přetekl pod hlavičku.
            ClipRect(child: _blurred(context, url, sigma: 24, dim: 0.25)),
            Center(
              child: SizedBox(
                width: constraints.maxHeight * maxAspect,
                height: constraints.maxHeight,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
                    stops: [0, 0.12, 0.88, 1],
                  ).createShader(rect),
                  child: photo,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBanner(BuildContext context, double t, String? blurSource) {
    final theme = Theme.of(context);
    // Maska: nahoře plná fotka, od ~45 % výšky plynule do průhledna --
    // pod ní prosvítá `AppBackground`, hlavička tak "vtéká" do stránky.
    Widget faded(Widget child) => ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.black, Colors.transparent],
            stops: [0, 0.45, 1],
          ).createShader(rect),
          child: child,
        );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Sbalený pruh: rozostřený obrázek + ztmavení, ať bílý název/šipka
        // zpět vždy čitelně stojí.
        Opacity(opacity: (1 - t).clamp(0.0, 1.0), child: _blurred(context, blurSource, dim: 0.55)),
        Opacity(
          opacity: t,
          child: faded(
            imageUrl != null
                ? _bannerPhoto(context, imageUrl!)
                : _blurred(context, bannerFallbackUrl, sigma: 24, dim: 0.25),
          ),
        ),
        // Ztmavení nahoře kvůli šipce zpět/akcím na světlých fotkách.
        IgnorePointer(
          child: Opacity(
            opacity: t,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Colors.black45, Colors.transparent],
                ),
              ),
            ),
          ),
        ),
        if (t > 0.05)
          Positioned(
            left: AppSpacing.md,
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: Opacity(
              opacity: t,
              child: DefaultTextStyle.merge(
                style: TextStyle(color: theme.colorScheme.onSurface),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (eyebrow != null)
                      Text(
                        eyebrow!.toUpperCase(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                          letterSpacing: 1.4,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.displaySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        shadows: [Shadow(color: theme.colorScheme.surface.withValues(alpha: 0.6), blurRadius: 16)],
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      ...subtitle,
                    ],
                  ],
                ),
              ),
            ),
          ),
        if (t < 0.4)
          Positioned(
            left: 56,
            right: (actions?.length ?? 0) * 48.0 + AppSpacing.md,
            bottom: 0,
            height: kToolbarHeight,
            child: Opacity(
              opacity: (1 - t / 0.4).clamp(0.0, 1.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.title,
    required this.imageUrl,
    required this.eyebrow,
    required this.subtitle,
    required this.circleImage,
    required this.placeholderIcon,
  });

  final String title;
  final String? imageUrl;
  final String? eyebrow;
  final List<Widget> subtitle;
  final bool circleImage;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = AppShapes.of(circleImage ? AppRadii.pill : AppRadii.sm);
    return GlassContainer(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      tint: Colors.black,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipPath(
                clipper: ShapeBorderClipper(shape: shape),
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: ArtworkImage(url: imageUrl, icon: placeholderIcon, iconSize: 40),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (eyebrow != null)
                      Text(
                        eyebrow!.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.75),
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      ...subtitle,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Klikatelný řádek v hlavičce (interpret, album) -- bílý podtržený text.
class HeroLink extends StatelessWidget {
  const HeroLink({super.key, required this.text, this.onTap, this.icon});

  final String text;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.color ?? Colors.white;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 16, color: base.withValues(alpha: 0.7)), const SizedBox(width: AppSpacing.xxs)],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: base.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
              decoration: onTap != null ? TextDecoration.underline : null,
              decorationColor: base.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    );
    if (onTap == null) return child;
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: child));
  }
}

/// Doplňkový šedý řádek v hlavičce (rok, počet skladeb...).
class HeroMeta extends StatelessWidget {
  const HeroMeta(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.color ?? Colors.white;
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: base.withValues(alpha: 0.7), fontSize: 12));
  }
}
