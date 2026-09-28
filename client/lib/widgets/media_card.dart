import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/artwork_provider.dart';
import '../theme/design_tokens.dart';
import '../theme/shapes.dart';

enum MediaCardShape { roundedSquare, circle }
enum MediaCardLayout { card, row }

/// Karta/řádek alba, interpreta nebo playlistu -- jediná komponenta pro
/// všechny mřížky/řady/seznamy "ne-skladeb" v appce (Home, Knihovna,
/// diskografie, hledání, rok v hudbě, detail skladby).
///
/// Obrázek: `imageUrl`, a když chybí, dohledá se přes `artworkKey`
/// (`recordingArtworkProvider`: obal alba -> fotka interpreta) -- backend
/// obrázky doplňuje průběžně na pozadí, takže `autoDispose` provider se při
/// další návštěvě zeptá znovu. Bez obojího tónovaný gradient s ikonou.
class MediaCard extends ConsumerWidget {
  const MediaCard({
    super.key,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.artworkKey,
    this.shape = MediaCardShape.roundedSquare,
    this.placeholderIcon = Symbols.album_rounded,
    this.layout = MediaCardLayout.card,
    this.animationIndex,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final ArtworkKey? artworkKey;
  final MediaCardShape shape;
  final IconData placeholderIcon;
  final MediaCardLayout layout;

  /// Pořadí pro staggered nástupní animaci (viz `TrackTile.animationIndex`).
  final int? animationIndex;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCircle = shape == MediaCardShape.circle;
    final cardShape = AppShapes.of(isCircle ? AppRadii.pill : AppRadii.md);
    final resolved = imageUrl ??
        (artworkKey != null ? ref.watch(recordingArtworkProvider(artworkKey!)).valueOrNull : null);
    final image = ArtworkImage(url: resolved, icon: placeholderIcon);

    Widget card = layout == MediaCardLayout.row
        ? _buildRow(context, image, isCircle)
        : _buildCard(context, image, cardShape, isCircle);

    if (animationIndex != null) {
      card = card
          .animate(delay: (animationIndex! * 60).ms)
          .fadeIn(duration: 300.ms, curve: Curves.easeOut)
          .slideY(begin: 0.08, end: 0, duration: 300.ms, curve: Curves.easeOutCubic);
    }
    return card;
  }

  Widget _buildCard(BuildContext context, Widget image, ShapeBorder cardShape, bool isCircle) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: AppShapes.md,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: isCircle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: cardShape,
                  shadows: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: ClipPath(clipper: ShapeBorderClipper(shape: cardShape), child: image),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isCircle ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.bodyMedium,
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: isCircle ? TextAlign.center : TextAlign.start,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, Widget image, bool isCircle) {
    final theme = Theme.of(context);
    final thumbShape = AppShapes.of(isCircle ? AppRadii.pill : AppRadii.sm);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: AppShapes.md,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          child: Row(
            children: [
              ClipPath(
                clipper: ShapeBorderClipper(shape: thumbShape),
                child: SizedBox(width: 48, height: 48, child: image),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              Icon(Symbols.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Obrázek s jednotným placeholderem (tónovaný gradient z aktuální barvy
/// nálady + ikona) pro načítání, chybu i "žádný obrázek" -- sdílený pro
/// karty, řádky i hlavičky, ať prázdné místo nikde nevypadá jinak.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({super.key, required this.url, this.icon = Symbols.album_rounded, this.iconSize = 32});

  final String? url;
  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final placeholder = ArtworkPlaceholder(icon: icon, iconSize: iconSize);
    if (url == null) return placeholder;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Dekódovat jen v rozlišení, ve kterém se obrázek opravdu kreslí --
        // obaly chodí jako 1000×1000, a desítky takových textur najednou
        // (mřížka knihovny, řady na Domů) na webu (CanvasKit/WebGL) vyčerpají
        // paměť GPU a karty se pak kreslily jako černé čtverce.
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logical = constraints.hasBoundedWidth ? constraints.maxWidth : 300.0;
        final px = (logical * dpr).clamp(64.0, 1000.0).round();
        return CachedNetworkImage(
          imageUrl: sizedArtworkUrl(url!, px),
          memCacheWidth: px,
          fit: BoxFit.cover,
          fadeInDuration: const Duration(milliseconds: 250),
          placeholder: (context, _) => placeholder,
          errorWidget: (context, _, __) => placeholder,
        );
      },
    );
  }
}

final _deezerSize = RegExp(r'/(\d+)x(\d+)-');
final _caaSize = RegExp(r'/front-(\d+)$');

/// Menší varianta obalu, když ho zdroj nabízí (Deezer CDN `NxN`, Cover Art
/// Archive `front-N`) -- miniatury nemusí stahovat 1000px originál.
String sizedArtworkUrl(String url, int px) {
  final target = px <= 250 ? 250 : (px <= 500 ? 500 : 1000);
  if (url.contains('dzcdn.net') && _deezerSize.hasMatch(url)) {
    return url.replaceFirst(_deezerSize, '/${target}x$target-');
  }
  if (url.contains('coverartarchive.org') && _caaSize.hasMatch(url)) {
    return url.replaceFirst(_caaSize, '/front-${target >= 1000 ? 1200 : target}');
  }
  return url;
}

class ArtworkPlaceholder extends StatelessWidget {
  const ArtworkPlaceholder({super.key, this.icon = Symbols.album_rounded, this.iconSize = 32});

  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: Center(child: Icon(icon, size: iconSize, color: scheme.onPrimaryContainer.withValues(alpha: 0.7))),
    );
  }
}
