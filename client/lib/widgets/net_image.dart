import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart' show apiClientProvider;

/// Síťový obrázek (obaly, fotky interpretů) -- JEDINÝ způsob, jak v appce
/// kreslit obrázek z URL.
///
/// Proč ne rovnou `CachedNetworkImage`: na webu (CanvasKit) se obrázek
/// dekóduje přes `<img>`/`ImageDecoder` do "líné" GPU textury navázané na
/// zdroj v prohlížeči. Po tom, co se nějakou dobu nekreslí (např. Domů pod
/// otevřeným přehrávačem s celoobrazovkovým rozmazáním), se taková textura
/// vrátí ČERNÁ -- živě reprodukováno: zavřít přehrávač → všechny obaly na
/// Domů černé, jen obal v mini přehrávači (kreslený i během přehrávače) OK.
/// [RasterizedImage] proto na webu každý obrázek jednou převede na běžný
/// pixelový (CPU) obrázek, který na GPU kontextu/cache nezávisí.
class NetImage extends StatefulWidget {
  const NetImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
    this.fadeIn = const Duration(milliseconds: 250),
  });

  final String url;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Widget? placeholder;
  final Duration fadeIn;

  @override
  State<NetImage> createState() => _NetImageState();
}

class _NetImageState extends State<NetImage> {
  // URL obrázku, který je právě vidět. Při změně URL (další skladba
  // v mini přehrávači, přeskládaný seznam) zůstane starý obrázek, dokud se
  // nový nenačte, a pak se prolnou -- dřív to mezitím bliklo zástupným
  // obrázkem.
  String? _shownUrl;

  // Velikost dekódování se drží: roztahování hlavičky tak nepřepíná mezi
  // velikostmi (každá = nové načtení a probliknutí). Jen zvětšuje.
  int? _decodeSize;

  @override
  Widget build(BuildContext context) {
    final fallback = widget.placeholder ?? const SizedBox.shrink();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return LayoutBuilder(builder: (context, constraints) {
      final longest = [constraints.maxWidth, constraints.maxHeight].where((v) => v.isFinite).fold<double>(0, math.max);
      if (longest > 0) {
        final bucket = decodeBucket(longest * dpr);
        if (_decodeSize == null || bucket > _decodeSize!) _decodeSize = bucket;
      }
      return _image(fallback, _decodeSize);
    });
  }

  Widget _image(Widget fallback, int? decodeSize) {
    final url = widget.url;
    return Image(
      image: netImageProvider(url, decodeSize: decodeSize),
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded) {
          _shownUrl = url;
          return child;
        }
        final Widget current;
        if (frame != null) {
          _shownUrl = url;
          current = KeyedSubtree(key: ValueKey(url), child: child);
        } else if (_shownUrl != null) {
          // Nový se ještě načítá -- `gaplessPlayback` kreslí ten starý.
          current = KeyedSubtree(key: ValueKey(_shownUrl), child: child);
        } else {
          current = KeyedSubtree(key: const ValueKey('placeholder'), child: fallback);
        }
        return AnimatedSwitcher(
          duration: widget.fadeIn,
          // `passthrough` -- výchozí layout AnimatedSwitcheru (Stack) dává
          // dětem VOLNÁ omezení, takže obrázek načtený asynchronně ignoroval
          // `fit: cover` a kreslil se v přirozeném poměru (živě: široká
          // fotka interpreta jen pruhem uprostřed vysoké hlavičky).
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.passthrough,
            alignment: Alignment.center,
            children: [...previous, if (current != null) current],
          ),
          child: current,
        );
      },
      // Obal z Cover Art Archive nepřišel (archive.org občas neodpovídá,
      // audit 7. 10.: Creep / Pablo Honey bez obalu) -> náhradní z Deezeru.
      errorBuilder: (context, _, __) {
        final mbid = caaMbid(url);
        if (mbid == null) return fallback;
        return FutureBuilder<String?>(
          future: _caaFallback(context, mbid),
          builder: (context, snap) {
            final alt = snap.data;
            if (alt == null || alt == url) return fallback;
            return NetImage(url: alt, fit: widget.fit, alignment: widget.alignment, placeholder: widget.placeholder);
          },
        );
      },
    );
  }
}

final _caaUrl = RegExp(r'coverartarchive\.org/(?:release|release-group)/([^/]+)/');

/// MBID alba z odkazu na Cover Art Archive (jinak `null`).
@visibleForTesting
String? caaMbid(String url) => _caaUrl.firstMatch(url)?.group(1);

// Jeden dotaz na album za běh appky (i když se obal kreslí na deseti místech).
final Map<String, Future<String?>> _caaFallbacks = {};

Future<String?> _caaFallback(BuildContext context, String mbid) {
  final ProviderContainer container;
  try {
    container = ProviderScope.containerOf(context, listen: false);
  } catch (_) {
    return Future.value();
  }
  return _caaFallbacks[mbid] ??= container
      .read(apiClientProvider)
      .getJson('/catalog/covers/fallback', query: {'mbid': mbid})
      .then((json) => json['url'] as String?)
      .catchError((Object _) {
        // Chyba sítě: příště zkusit znovu.
        _caaFallbacks.remove(mbid);
        return null;
      });
}

/// Provider pro [url] -- na webu rasterizovaný (viz [NetImage]).
///
/// `decodeSize`: dekódovat jen na tuhle velikost delší strany (px). Obaly
/// z Deezeru mají 1000×1000 = 4 MB pixelů v paměti; stránka interpreta s
/// diskografií jich načte desítky a iPhone (Safari) pak appku při otevření
/// interpreta zamrazil (podezření, viz web/index.html "černá skříňka").
ImageProvider netImageProvider(String url, {int? decodeSize}) {
  ImageProvider inner = CachedNetworkImageProvider(url);
  if (decodeSize != null) {
    inner = ResizeImage(inner, width: decodeSize, height: decodeSize, policy: ResizeImagePolicy.fit);
  }
  return kIsWeb ? RasterizedImage(inner) : inner;
}

/// Velikost dekódování zaokrouhlená nahoru na pár stupňů -- při animaci
/// (roztahování hlavičky) se tak obrázek nenačítá znovu každý snímek.
int decodeBucket(double pixels) {
  // 384/768 navíc: dlaždice ~180 pt na 3x (540 px) se dřív dekódovala na
  // 1024 = 4 MB místo ~2,3 MB a cache obrázků se rychle přepisovala.
  for (final size in const [128, 256, 384, 512, 768, 1024]) {
    if (pixels <= size) return size;
  }
  return 2048;
}

/// Obalí jiný `ImageProvider` a výsledný obrázek jednou převede na
/// pixelový (CPU) obrázek -- viz [NetImage].
@immutable
class RasterizedImage extends ImageProvider<RasterizedImage> {
  const RasterizedImage(this.inner);

  final ImageProvider inner;

  @override
  Future<RasterizedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(RasterizedImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load());

  Future<ImageInfo> _load() async {
    final source = await _resolveFirstFrame(inner);
    // Původní (GPU) obrázek z cache vyhodit -- jinak tam na webu zůstával
    // vedle naší CPU kopie a paměť na obrázky se zdvojnásobila.
    try {
      PaintingBinding.instance.imageCache.evict(await inner.obtainKey(ImageConfiguration.empty));
    } catch (_) {}
    try {
      final bytes = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return ImageInfo(image: source.clone());
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes.buffer.asUint8List(),
        source.width,
        source.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return ImageInfo(image: await completer.future);
    } finally {
      source.dispose();
    }
  }

  static Future<ui.Image> _resolveFirstFrame(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
        scheduleMicrotask(() => stream.removeListener(listener));
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
        scheduleMicrotask(() => stream.removeListener(listener));
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @override
  bool operator ==(Object other) => other is RasterizedImage && other.inner == inner;

  @override
  int get hashCode => Object.hash(RasterizedImage, inner);
}
