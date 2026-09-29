import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
class NetImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final fallback = placeholder ?? const SizedBox.shrink();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return LayoutBuilder(builder: (context, constraints) {
      final longest = [constraints.maxWidth, constraints.maxHeight].where((v) => v.isFinite).fold<double>(0, math.max);
      return _image(fallback, longest > 0 ? decodeBucket(longest * dpr) : null);
    });
  }

  Widget _image(Widget fallback, int? decodeSize) {
    return Image(
      image: netImageProvider(url, decodeSize: decodeSize),
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSyncLoaded) {
        if (wasSyncLoaded) return child;
        return AnimatedSwitcher(
          duration: fadeIn,
          // `passthrough` -- výchozí layout AnimatedSwitcheru (Stack) dává
          // dětem VOLNÁ omezení, takže obrázek načtený asynchronně ignoroval
          // `fit: cover` a kreslil se v přirozeném poměru (živě: široká
          // fotka interpreta jen pruhem uprostřed vysoké hlavičky).
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.passthrough,
            alignment: Alignment.center,
            children: [...previous, if (current != null) current],
          ),
          child: frame == null ? KeyedSubtree(key: const ValueKey('placeholder'), child: fallback) : child,
        );
      },
      errorBuilder: (context, _, __) => fallback,
    );
  }
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
  for (final size in const [128, 256, 512, 1024]) {
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
