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
  return _accentFutures.putIfAbsent(imageUrl, () => _extract(imageUrl, size).then((color) {
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
  final raw = (vibrantMatters ? vibrant.color : null) ??
      dominant?.color ??
      palette.mutedColor?.color ??
      vibrant?.color;
  return raw == null ? null : normalizeAccent(raw);
}

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
