import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

/// Dominantní/vibrantní barva obalu -- sdílená mezi `AudioPlayerController`
/// (barva právě hrající skladby, pohání globální M3 seed appky) a
/// [screenAccentColorProvider] (barva obalu, na který se uživatel zrovna
/// dívá, pro hlavičky Release/Artist -- nezávisle na tom, co zrovna hraje).
/// Dřív žila jen jako privátní metoda `AudioPlayerController`u; teď ji
/// potřebují oba případy, tak je to samostatná funkce.
Future<Color?> extractAccentColor(String imageUrl) {
  // Jedna analýza na URL za běh appky -- návrat na už viděné album/interpreta
  // pak barvu má okamžitě (žádné probliknutí přes výchozí barvu, než se
  // obal znovu stáhne a zanalyzuje).
  return _accentFutures.putIfAbsent(
      imageUrl,
      () => _extract(imageUrl).then((color) {
            if (color == null) {
              // Neúspěch necachovat natrvalo -- backend obrázky doplňuje
              // průběžně, příští pokus už může uspět.
              _accentFutures.remove(imageUrl);
            } else {
              _accentCache[imageUrl] = color;
            }
            return color;
          }));
}

final Map<String, Future<Color?>> _accentFutures = {};

/// Jedna analýza obalu pro všechny tři pohledy (akcent, podpůrné tóny,
/// charakter) -- dřív si ho každý procházel zvlášť.
Future<PaletteGenerator> _paletteFor(String imageUrl) {
  final future = _paletteFutures.putIfAbsent(
    imageUrl,
    // Stejné vstupy jako dřív (celý obal, oblast 120 px): zmenšený obrázek
    // dával jiné poměry barev a u některých obalů divné pozadí (živě
    // nahlášeno). Sdílí se jen výsledek mezi akcentem, tóny a charakterem.
    () => PaletteGenerator.fromImageProvider(
      _providerFor(imageUrl),
      size: const Size(120, 120),
      maximumColorCount: 16,
      // Výchozí filtr knihovny zahazuje i celé pásmo "pleťových" tónů
      // (odstín ~10–37°) -- cihlová, oranžová a hnědá z obalu se tak do
      // palety nikdy nedostaly (živě: oranžová kšiltovka chyběla celou
      // skladbu). Vynechat jen skoro černou a skoro bílou.
      filters: const [_avoidBlackWhite],
    ),
  );
  // Neúspěch neukládat (obal se může doplnit později); hotové palety drží
  // jejich vlastní cache výš, tahle mapa je jen na souběžné dotazy.
  future.whenComplete(() => _paletteFutures.remove(imageUrl)).ignore();
  return future;
}

final Map<String, Future<PaletteGenerator>> _paletteFutures = {};

/// Testy (náhledy pozadí z obalů na disku) podstrčí vlastní obrázky.
@visibleForTesting
ImageProvider Function(String url)? debugCoverProvider;

ImageProvider _providerFor(String url) => debugCoverProvider?.call(url) ?? CachedNetworkImageProvider(url);

/// Jemnější rozbor obalu pro pozadí "Nové": vlastní průchod pixely
/// zmenšeného obalu (64×64), ne median-cut palety -- ta drobné výrazné
/// plochy (modrý nápis na šedém obalu) slila s okolím. Výsledek: podíl skoro
/// černé / skoro bílé plochy (krém a papír se počítají k bílé) a barevné
/// odstíny od největší plochy (koše po 30°, sousední podobné sloučené);
/// drobné jen když jsou opravdu syté.
Future<({double black, double white, List<({Color color, double share})> hues})> _fineColors(String imageUrl) async {
  const none = (black: 0.0, white: 0.0, hues: <({Color color, double share})>[]);
  try {
    final image = await _decodeSmall(_providerFor(imageUrl), 64);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width, h = image.height;
    image.dispose();
    if (data == null) return none;
    const bins = 12;
    final count = List<double>.filled(bins, 0);
    final chromaSum = List<double>.filled(bins, 0);
    final r = List<double>.filled(bins, 0), g = List<double>.filled(bins, 0), b = List<double>.filled(bins, 0);
    var total = 0, black = 0, white = 0;
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      if (data.getUint8(o + 3) < 128) continue;
      final cr = data.getUint8(o) / 255, cg = data.getUint8(o + 1) / 255, cb = data.getUint8(o + 2) / 255;
      total++;
      final mx = math.max(cr, math.max(cg, cb)), mn = math.min(cr, math.min(cg, cb));
      final l = (mx + mn) / 2, chroma = mx - mn;
      if (l < 0.12 && chroma < 0.08) {
        black++;
        continue;
      }
      if ((l > 0.86 && chroma < 0.08) || (l > 0.72 && chroma < 0.18)) {
        white++;
        continue;
      }
      if (chroma < 0.06) continue;
      double hue;
      if (mx == cr) {
        hue = 60 * (((cg - cb) / chroma) % 6);
      } else if (mx == cg) {
        hue = 60 * ((cb - cr) / chroma + 2);
      } else {
        hue = 60 * ((cr - cg) / chroma + 4);
      }
      final k = ((hue + 360) % 360 / (360 / bins)).floor() % bins;
      count[k] += 1;
      chromaSum[k] += chroma;
      // Reprezentant koše: průměr vážený sytostí (výrazné pixely víc).
      r[k] += cr * chroma;
      g[k] += cg * chroma;
      b[k] += cb * chroma;
    }
    if (total == 0) return none;
    // Sousední koše slít do skupin (barva přes hranici 30° je jedna barva).
    final groups = <({double n, double c, double r, double g, double b})>[];
    final used = List<bool>.filled(bins, false);
    final order = List<int>.generate(bins, (i) => i)..sort((x, y) => count[y].compareTo(count[x]));
    for (final k in order) {
      if (used[k] || count[k] == 0) continue;
      var n = count[k], c = chromaSum[k], rr = r[k], gg = g[k], bb = b[k];
      used[k] = true;
      for (final j in [(k + 1) % bins, (k + bins - 1) % bins]) {
        if (!used[j] && count[j] > 0 && count[j] >= count[k] * 0.25) {
          used[j] = true;
          n += count[j];
          c += chromaSum[j];
          rr += r[j];
          gg += g[j];
          bb += b[j];
        }
      }
      groups.add((n: n, c: c, r: rr, g: gg, b: bb));
    }
    final hues = <({Color color, double share})>[];
    for (final grp in groups) {
      final share = grp.n / total;
      final meanChroma = grp.c / grp.n;
      // Velké plochy i tlumené; malé jen syté (nápis, detail obalu).
      if (share < 0.006 || (share < 0.03 && meanChroma < 0.22) || meanChroma < 0.08) continue;
      final color = Color.from(
        alpha: 1,
        red: (grp.r / grp.c).clamp(0.0, 1.0),
        green: (grp.g / grp.c).clamp(0.0, 1.0),
        blue: (grp.b / grp.c).clamp(0.0, 1.0),
      );
      // Stejná barva ve dvou nesousedních skupinách (slabý soused) -- k větší.
      final hue = HSLColor.fromColor(color).hue;
      final i = hues.indexWhere((x) => (((HSLColor.fromColor(x.color).hue - hue + 540) % 360) - 180).abs() < 25);
      if (i >= 0) {
        hues[i] = (color: hues[i].color, share: hues[i].share + share);
      } else {
        hues.add((color: color, share: share));
      }
    }
    hues.sort((a, b) => b.share.compareTo(a.share));
    return (black: black / total, white: white / total, hues: hues);
  } catch (_) {
    return none;
  }
}

Future<ui.Image> _decodeSmall(ImageProvider provider, int size) {
  final completer = Completer<ui.Image>();
  final stream = ResizeImage(provider, width: size, height: size).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    stream.removeListener(listener);
    completer.complete(info.image.clone());
    info.dispose();
  }, onError: (e, st) {
    stream.removeListener(listener);
    completer.completeError(e, st);
  });
  stream.addListener(listener);
  return completer.future;
}

bool _avoidBlackWhite(HSLColor color) => color.lightness > 0.05 && color.lightness < 0.95;
final Map<String, Color> _accentCache = {};

/// Už spočítaná barva pro URL (synchronně), nebo `null`, pokud ještě ne.
Color? cachedAccentColor(String? imageUrl) => imageUrl == null ? null : _accentCache[imageUrl];

Future<Color?> _extract(String imageUrl) async {
  try {
    final palette = await _paletteFor(imageUrl);
    return pickAccent(palette);
  } catch (_) {
    // Obal se nepodařilo stáhnout/zanalyzovat -- volající použije svůj fallback.
    return null;
  }
}

/// Seed pro M3 schéma z libovolného obalu -- čistě bílé/černé/šedé obaly
/// by daly buď vybledlé, nebo "špinavé" schéma. Světlost se stáhne do
/// středu, a téměř nesytá barva dostane aspoň jemný nádech sytosti (odstín
/// zůstává z obalu), ať je schéma pořád příjemné a kontrastní.
/// Vybere barvu obalu: "živá" (vibrant) barva jen když na obalu opravdu
/// něco znamená (≥ 6 % plochy převládající barvy), jinak převládající.
/// Dřív vyhrála vibrant barva i z drobného detailu -- bílý obal s pár
/// červenými tečkami pak obarvil celou appku do červena.
Color? pickAccent(PaletteGenerator palette) {
  final dominant = palette.dominantColor;
  final vibrant = palette.vibrantColor;
  final base = dominant?.population ?? 0;
  final vibrantMatters = vibrant != null && base > 0 && vibrant.population >= base * 0.06;
  var raw = (vibrantMatters ? vibrant.color : null) ?? dominant?.color ?? palette.mutedColor?.color ?? vibrant?.color;
  if (raw != null && isAchromatic(raw)) {
    // Šedá převládající barva, ale obal jinak barevný (tlumená růžovo-béžová
    // fotka) -- dřív z toho byla čistě šedá appka, i když obal šedý není
    // (živě nahlášeno). Když barevné plochy dohromady tvoří ≥ 20 % obalu,
    // vzít tu s největší "váhou" (plocha × chroma); skutečně černobílé
    // obaly žádné nemají.
    double chroma(Color c) {
      final hsl = HSLColor.fromColor(c);
      return (1 - (2 * hsl.lightness - 1).abs()) * hsl.saturation;
    }

    final total = palette.paletteColors.fold<int>(0, (sum, c) => sum + c.population);
    final colored = palette.paletteColors.where((c) => !isAchromatic(c.color) && chroma(c.color) >= 0.06).toList();
    final coloredShare = colored.fold<int>(0, (sum, c) => sum + c.population);
    if (total > 0 && coloredShare >= total * 0.2) {
      colored.sort((a, b) => (b.population * chroma(b.color)).compareTo(a.population * chroma(a.color)));
      raw = colored.first.color;
    } else if (total > 0) {
      // Vybledlý obal (šedé město v oparu s pletí a fialovým trikem): žádná
      // plocha není "barevná", ale dohromady mají nádech. Průměrný odstín
      // vážený plochou × chromou -> tlumený tón (sytost těsně nad hranicí
      // černobílé), ne čistý grafit (živě nahlášeno). Opravdu černobílé
      // obaly mají průměrnou chromu ~0 a zůstanou šedé.
      var x = 0.0, y = 0.0, weight = 0.0;
      for (final c in palette.paletteColors) {
        final ch = chroma(c.color);
        if (ch < 0.04) continue;
        final w = c.population * ch;
        final hue = HSLColor.fromColor(c.color).hue * math.pi / 180;
        x += math.cos(hue) * w;
        y += math.sin(hue) * w;
        weight += w;
      }
      if (weight / total >= 0.02) {
        final hue = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
        return HSLColor.fromAHSL(1, hue, 0.2, 0.45).toColor();
      }
    }
  }
  return raw == null ? null : normalizeAccent(raw);
}

/// Podpůrné tóny pro gradient pozadí -- z obalu, ale jen blízké hlavní
/// barvě (±[supportHueRange]°), ať se zachová harmonický "jedna barva s
/// nádechy" efekt; kontrastní barvy obalu (modrý obal s oranžovým
/// nápisem) se ignorují a pozadí si pro ně dopočítá vlastní posun odstínu.
/// Černobílé obaly podpůrné tóny nemají (neutrální paleta).
const supportHueRange = 40.0;

Future<List<Color>> extractSupportTones(String imageUrl) {
  return _supportFutures.putIfAbsent(imageUrl, () async {
    try {
      final palette = await _paletteFor(imageUrl);
      final main = pickAccent(palette);
      if (main == null || isAchromatic(main)) return const <Color>[];
      final mainHue = HSLColor.fromColor(main).hue;
      final total = palette.paletteColors.fold<int>(0, (sum, c) => sum + c.population);
      final tones = <Color>[];
      for (final swatch in [...palette.paletteColors]..sort((a, b) => b.population.compareTo(a.population))) {
        final hsl = HSLColor.fromColor(swatch.color);
        if (hsl.saturation < achromaticSaturation) continue;
        if (total > 0 && swatch.population < total * 0.02) continue; // drobné detaily ne
        final diff = ((hsl.hue - mainHue + 540) % 360) - 180;
        if (diff.abs() < 6 || diff.abs() > supportHueRange) continue; // stejná nebo moc vzdálená
        if (tones.any((t) => (HSLColor.fromColor(t).hue - hsl.hue).abs() < 8)) continue;
        tones.add(normalizeAccent(swatch.color));
        if (tones.length == 2) break;
      }
      return tones;
    } catch (_) {
      _supportFutures.remove(imageUrl);
      return const <Color>[];
    }
  });
}

final Map<String, Future<List<Color>>> _supportFutures = {};

final supportTonesProvider = FutureProvider.autoDispose.family<List<Color>, String>((ref, imageUrl) async {
  final tones = await extractSupportTones(imageUrl);
  // Neúspěch (ne legitimně prázdné tóny šedého obalu) -- zkusit znovu.
  if (!_supportFutures.containsKey(imageUrl)) _retryLater(ref, imageUrl);
  return tones;
});

/// Analýza obalu se na pozadí (zamčený telefon, Safari) občas nepovede --
/// výsledek pak zůstal prázdný až do reloadu a pozadí vyšlo jen z akcentu
/// (celé červené místo modrého s červenou, živě nahlášeno). Zkusí se znovu
/// po 4 s, 15 s a 60 s.
final Map<String, int> _retries = {};

void _retryLater(Ref ref, String imageUrl) {
  final n = _retries[imageUrl] ?? 0;
  if (n >= 3) return;
  _retries[imageUrl] = n + 1;
  final timer = Timer(const [Duration(seconds: 4), Duration(seconds: 15), Duration(seconds: 60)][n], ref.invalidateSelf);
  ref.onDispose(timer.cancel);
}

/// Po návratu do appky: dát neúspěšným obalům další šanci (znovu 3 pokusy).
void resetCoverRetries() => _retries.clear();

/// "Charakter" obalu -- průměrná barevnost (chroma, 0..1) a světlost celé plochy (vážená
/// zastoupením barev), ne jen odstín hlavní barvy. Pastelový krémový obal
/// a sytě červený obal můžou mít podobný odstín, ale úplně jinou náladu;
/// pozadí podle tohohle ladí sytost a světlost své palety.
///
/// `tones` = skutečné převládající barvy obalu (nenormalizované), seřazené
/// podle zastoupení (≥ 3 % plochy, max 5) -- krémový papír s vínovou
/// kresbou má dát krémovo-pískové pozadí s tmavě vínovými akcenty, ne
/// červené pole podle jediné "živé" barvy.
///
/// `accent` = malá, ale výrazná kontrastní barva obalu (žlutá kresba na
/// tmavě modrém) -- pozadí jí dá jedno světlo, jinak by se úplně ztratila.
///
/// `black` / `white` = podíl skoro černé / skoro bílé plochy obalu (0..1),
/// `hues` = barevné odstíny jemnějšího rozboru (pozadí "Nové").
///
/// `guests` = další výrazné barvy obalu (≥ 2 % plochy, zřetelně barevné,
/// podobné odstíny sloučené), od největší plochy. Pozadí je po jedné
/// ukazuje ve světlých záblescích (viz `AppBackground`), ať se objeví i
/// barvy, které paleta sama nemá.
typedef CoverCharacter = ({
  double saturation,
  double lightness,
  List<Color> tones,
  Color? accent,
  List<({Color color, double share})> guests,
  double black,
  double white,
  List<({Color color, double share})> hues,
});

Future<CoverCharacter?> extractCoverCharacter(String imageUrl) {
  return _characterFutures.putIfAbsent(imageUrl, () async {
    try {
      final palette = await _paletteFor(imageUrl);
      var total = 0;
      var sat = 0.0;
      var light = 0.0;
      for (final swatch in palette.paletteColors) {
        final hsl = HSLColor.fromColor(swatch.color);
        total += swatch.population;
        // Chroma (skutečná barevnost), ne HSL sytost -- bledý krém má HSL
        // sytost vysokou, ale barevně je skoro neutrální.
        sat += (1 - (2 * hsl.lightness - 1).abs()) * hsl.saturation * swatch.population;
        light += hsl.lightness * swatch.population;
      }
      if (total == 0) return null;
      final tones = [
        for (final swatch in [...palette.paletteColors]..sort((a, b) => b.population.compareTo(a.population)))
          if (swatch.population >= total * 0.03) swatch.color,
      ].take(5).toList();
      double chromaOf(Color c) {
        final hsl = HSLColor.fromColor(c);
        return (1 - (2 * hsl.lightness - 1).abs()) * hsl.saturation;
      }

      Color? accent;
      if (tones.isNotEmpty && chromaOf(tones.first) >= 0.04) {
        final mainHue = HSLColor.fromColor(tones.first).hue;
        var best = 0.0;
        for (final swatch in palette.paletteColors) {
          if (swatch.population < total * 0.015) continue;
          final ch = chromaOf(swatch.color);
          if (ch < 0.12) continue;
          final diff = (((HSLColor.fromColor(swatch.color).hue - mainHue + 540) % 360) - 180).abs();
          if (diff < 60) continue;
          final score = ch * swatch.population;
          if (score > best) {
            best = score;
            accent = swatch.color;
          }
        }
      }
      // Hosté: swatche ≥ 2 % plochy a chroma ≥ 0.1 (HSL chroma; šedé
      // a přechodové pixely mezi barvami ne), podobné odstíny (< 30°)
      // sečtené pod tu s větší plochou.
      final guests = <({Color color, double share})>[];
      for (final swatch in [...palette.paletteColors]..sort((a, b) => b.population.compareTo(a.population))) {
        final share = swatch.population / total;
        if (share < 0.02 || chromaOf(swatch.color) < 0.1) continue;
        final hue = HSLColor.fromColor(swatch.color).hue;
        final i = guests.indexWhere(
            (g) => (((HSLColor.fromColor(g.color).hue - hue + 540) % 360) - 180).abs() < 30);
        if (i >= 0) {
          guests[i] = (color: guests[i].color, share: guests[i].share + share);
        } else {
          guests.add((color: swatch.color, share: share));
        }
      }
      final fine = await _fineColors(imageUrl);
      return (
        saturation: sat / total,
        lightness: light / total,
        tones: tones,
        accent: accent,
        guests: guests,
        black: fine.black,
        white: fine.white,
        hues: fine.hues,
      );
    } catch (_) {
      _characterFutures.remove(imageUrl);
      return null;
    }
  });
}

final Map<String, Future<CoverCharacter?>> _characterFutures = {};

final coverCharacterProvider = FutureProvider.autoDispose.family<CoverCharacter?, String>((ref, imageUrl) async {
  final character = await extractCoverCharacter(imageUrl);
  if (character == null) _retryLater(ref, imageUrl);
  return character;
});

/// Pod touhle sytostí je barva prakticky šedá/černobílá -- nemá odstín.
const achromaticSaturation = 0.12;

bool isAchromatic(Color color) => HSLColor.fromColor(color).saturation < achromaticSaturation;

Color normalizeAccent(Color color) {
  final hsl = HSLColor.fromColor(color);
  final lightness = hsl.lightness.clamp(0.32, 0.62);
  // Šedá/bílá/černá nemá žádný odstín a HSL ji vede jako 0° = ČERVENÁ.
  // Dřív se u ní sytost zvedla na 0.12, takže černobílé obaly obarvily appku
  // do červena (živě nahlášeno). Teď zůstane neutrální grafit (sytost 0).
  if (hsl.saturation < achromaticSaturation) {
    return hsl.withLightness(lightness).withSaturation(0).toColor();
  }
  return hsl.withLightness(lightness).withSaturation(hsl.saturation.clamp(0.0, 0.9)).toColor();
}

/// Jednotná délka/křivka všech barevných přechodů (téma, přehrávač,
/// hlavičky, pozadí) -- ať se všechno přebarví najednou a stejně rychle.
/// Stejně dlouho jako přebarvení pozadí zrnko po zrnku (`AppBackground`
/// ji používá taky) -- dřív UI 0,7 s a pozadí 2,8 s, takže tlačítka
/// a lišty měly novou barvu dávno před pozadím (živě nahlášeno).
const accentTransitionDuration = Duration(milliseconds: 2800);
const accentTransitionCurve = Curves.easeInOutCubic;

/// Plynule animovaná barva nálady -- pro místa, co barvu čtou přímo
/// (`PlayerBar`, `NowPlayingScreen`), ne přes `Theme` (ten animuje
/// `MaterialApp` sám, viz `themeAnimationDuration` v `app.dart`).
class AnimatedAccent extends StatelessWidget {
  const AnimatedAccent({super.key, required this.color, required this.builder});

  final Color color;
  final Widget Function(BuildContext context, Color color) builder;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: accentTransitionDuration,
      curve: accentTransitionCurve,
      builder: (context, value, _) => builder(context, value ?? color),
    );
  }
}

/// Barva obalu konkrétní obrazovky (Release/Artist header), na rozdíl od
/// `AudioPlayerState.accentColor` (barva toho, co zrovna hraje). Prohlížení
/// alba, které zrovna nehraje, by jinak zůstalo barevně "neutrální" i když
/// appka barvu jeho obalu umí spočítat stejně snadno jako pro přehrávač.
final screenAccentColorProvider = FutureProvider.autoDispose.family<Color?, String>((ref, imageUrl) {
  return extractAccentColor(imageUrl);
});

/// Zásobník barev otevřených detailových obrazovek (Album, Interpret,
/// Skladba, Playlist) v pořadí, jak byly otevřené -- viz `ScreenAccent`.
/// Zásobník, ne jedna hodnota: po návratu z detailu skladby zpátky na
/// album musí barva alba zase naskočit, ne spadnout na "nic" (dřív to
/// `dispose()` detailu vynulovalo, i když pod ním zůstalo otevřené album).
class ScreenAccentStack extends StateNotifier<List<MapEntry<Object, Color?>>> {
  ScreenAccentStack() : super(const []);

  void set(Object owner, Color? color) {
    final index = state.indexWhere((e) => identical(e.key, owner));
    if (index >= 0) {
      if (state[index].value == color) return;
      state = [...state]..[index] = MapEntry(owner, color);
    } else {
      state = [...state, MapEntry(owner, color)];
    }
  }

  void remove(Object owner) {
    state = state.where((e) => !identical(e.key, owner)).toList();
  }
}

final screenAccentStackProvider =
    StateNotifierProvider<ScreenAccentStack, List<MapEntry<Object, Color?>>>((ref) => ScreenAccentStack());

/// Barva PRÁVĚ PROHLÍŽENÉ obrazovky (nejvrchnější otevřený detail) --
/// `app.dart` ji čte jako seed pro globální M3 téma PŘEDNOSTNĚ před
/// `AudioPlayerState.accentColor` (barva hrající skladby), a `AppBackground`
/// podle ní přepíná vícebarevný/monochromatický gradient. `null`, když žádný
/// detail otevřený není (Domů, Hledat, Knihovna, Profil).
final activeScreenAccentProvider = Provider<Color?>((ref) {
  final stack = ref.watch(screenAccentStackProvider);
  return stack.isEmpty ? null : stack.last.value;
});
