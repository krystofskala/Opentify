import 'dart:math' as math;

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
Future<Color?> extractAccentColor(String imageUrl, {Size size = const Size(120, 120)}) {
  // Jedna analýza na URL za běh appky -- návrat na už viděné album/interpreta
  // pak barvu má okamžitě (žádné probliknutí přes výchozí barvu, než se
  // obal znovu stáhne a zanalyzuje).
  return _accentFutures.putIfAbsent(
      imageUrl,
      () => _extract(imageUrl, size).then((color) {
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
final Map<String, Color> _accentCache = {};

/// Už spočítaná barva pro URL (synchronně), nebo `null`, pokud ještě ne.
Color? cachedAccentColor(String? imageUrl) => imageUrl == null ? null : _accentCache[imageUrl];

Future<Color?> _extract(String imageUrl, Size size) async {
  try {
    final palette = await PaletteGenerator.fromImageProvider(
      CachedNetworkImageProvider(imageUrl),
      size: size,
      maximumColorCount: 16,
    );
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
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(imageUrl),
        size: const Size(120, 120),
        maximumColorCount: 16,
      );
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

final supportTonesProvider = FutureProvider.autoDispose.family<List<Color>, String>((ref, imageUrl) {
  return extractSupportTones(imageUrl);
});

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
});

Future<CoverCharacter?> extractCoverCharacter(String imageUrl) {
  return _characterFutures.putIfAbsent(imageUrl, () async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(imageUrl),
        size: const Size(120, 120),
        maximumColorCount: 16,
      );
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
      return (saturation: sat / total, lightness: light / total, tones: tones, accent: accent, guests: guests);
    } catch (_) {
      _characterFutures.remove(imageUrl);
      return null;
    }
  });
}

final Map<String, Future<CoverCharacter?>> _characterFutures = {};

final coverCharacterProvider = FutureProvider.autoDispose.family<CoverCharacter?, String>((ref, imageUrl) {
  return extractCoverCharacter(imageUrl);
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
const accentTransitionDuration = Duration(milliseconds: 700);
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
