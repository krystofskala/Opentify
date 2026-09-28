import 'dart:async';
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
    return Image(
      image: netImageProvider(url),
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
ImageProvider netImageProvider(String url) {
  final ImageProvider inner = CachedNetworkImageProvider(url);
  return kIsWeb ? RasterizedImage(inner) : inner;
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
