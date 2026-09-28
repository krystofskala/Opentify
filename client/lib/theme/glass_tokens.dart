import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Designový systém appky = Apple Liquid Glass + Google Material 3
/// Expressive. JEDINÝ zdroj pravdy pro sklo, tlačítka, přepínače, segmenty,
/// vyhledávací pole, tab bar a sheety (komponenty v `widgets/glass/`).
/// Hodnoty vychází z Apple Human Interface Guidelines (iOS 26) a z M3
/// Expressive tokenů v AndroidX (`ExpressiveMotionTokens.kt`,
/// `ShapeTokens.kt`), ne z odhadu -- u každé skupiny odkaz na zdroj.
///
/// ## Pravidlo mixu (drž se ho u každé nové obrazovky)
/// - **Sklo = navigace a překryvy** (Liquid Glass): tab bar, mini přehrávač,
///   vyhledávací pole, sheety/menu, horní lišta pod kterou odjel obsah.
///   Vibrance, vlasová hrana, jeden měkký stín, neutrální tón.
/// - **Expresivní tónová barva + tvary = obsah a akce** (M3 Expressive):
///   tlačítka, vybrané stavy, čipy, karty -- tónové kontejnery ze seedu
///   (`primaryContainer`/`secondaryContainer`, ne šedá), tvarová
///   morfologie (stisk zmáčkne rohy, play↔pause mění tvar), hravé tvary
///   (`ExpressiveShapes`) pro play tlačítko a obal v přehrávači.
/// - **Pružiny = veškerý pohyb** (`Expressive.spatial*` pro polohu/velikost/
///   tvar -- smí překmitnout; `Expressive.effects*` pro barvu/průhlednost
///   -- bez překmitu).
/// Ovládací prvky vypadají jako JEDEN systém: přepínač = iOS proporce +
/// tónové M3 barvy + pružina; segmenty = sklo/plochá stopa + tónová
/// vybraná kapsle; hlavní tlačítko = M3 plná tónová kapsle s morfem při
/// stisku; vyhledávání = skleněná kapsle.
///
/// ## Kdy sklo ANO / NE
/// HIG Materials (https://developer.apple.com/design/human-interface-guidelines/materials):
/// > "Liquid Glass forms a distinct functional layer for controls and
/// > navigation elements ... that floats above the content layer."
/// > "Don't use Liquid Glass in the content layer." / "Use Liquid Glass
/// > effects sparingly."
///
/// Sklo (`GlassContainer` s rozmazáním) jen na PLOVOUCÍ vrstvě:
/// tab bar, mini přehrávač, vyhledávací pole v horní liště, horní lišta když
/// pod ní odjede obsah, sheety/menu, panel návrhů, lišta vícenásobného
/// výběru. NIKDY na kartách, řádcích seznamu, čipech, dialozích-kartách ani
/// inline tlačítkách v obsahu -- ty jsou ploché (`GlassButton.tonal`,
/// `GlassSegmentedControl` stopa je plochá výplň).
/// Nikdy sklo na skle se dvěma rozmazáními -- vnořený panel používá
/// `GlassContainer(blur: false)`.
/// ## Sjednocená pravidla (design audit, schváleno) -- drž se jich
/// - **Škála zaoblení**: jedna, M3 (`Expressive.corner*`). Plán: `AppRadii`
///   se stane aliasy (xs 8, sm 12, md 16, lg 20, xl 28); žádné literály.
///   Náhled/obrázek uvnitř kontejneru má o stupeň menší poloměr než
///   kontejner.
/// - **Vybraný stav** (segmenty, taby, čipy -- jeden recept): skleněná
///   "čočka" `SelectedCapsule` po vzoru iOS 26 -- převážně průhledná,
///   v segmentech jemně tónovaná `primary` (tab bar neutrální), ostrá
///   gradientní světelná hrana (nahoře jasná, dole slábne), jemný odlesk
///   jen v horních 40 %, BEZ vrženého stínu a tmavé hrany (působilo
///   falešně); text/ikona `onSurface` w700.
///   NIKDY plná barevná pilulka s lesklým pruhem přes půl výšky -- působilo
///   to levně (zpětná vazba uživatele).
/// - **Barvy textu na skle**: primární `onSurface`, sekundární
///   `onSurfaceVariant` (0.8). Bílá JEN nad médii (obal/fotka) spolu se
///   ztmavením `GlassTokens.mediaDimming`. Žádné natvrdo `Colors.white*`.
/// - **Pohyb**: `Motion.enter / exit / state` (pružiny), nic jiného.
/// - **Ikony**: Material Symbols Rounded, `weight 300`, `opticalSize 24`
///   (globálně v `app_theme.dart`); `fill: 1` JEN pro vybraný/aktivní stav,
///   jinak obrys.
/// - **Tlačítka**: hlavní akce `primaryContainer` (ne `primary`), vedlejší
///   tónová `secondaryContainer`; dvojice akcí v jedné spojené skupině.
/// - **Řádek ovládání v obsahu** (filtr, řazení, výběr): vše 40 px, jedna
///   výplň `surfaceContainerHigh` 0.72.
class GlassTokens {
  const GlassTokens._();

  // --- Materiál -----------------------------------------------------------

  /// Rozmazání "regular" varianty (chrome). HIG Materials: regular varianta
  /// "blurs and adjusts the luminosity of background content to maintain
  /// legibility".
  /// Sjednocení (audit): 28 → 32 -- přes zrnité pozadí má chrome působit
  /// hladce matně, ne zrnitě.
  static const double blur = 32;

  /// Silnější rozmazání pro celoobrazovkový přehrávač (obal za sklem).
  static const double blurPlayer = 56;

  /// Vibrance -- zvýšená sytost toho, co je za sklem. Klíč k Apple vzhledu:
  /// obsah za sklem zůstává živý, ne vybledle šedý. (Materials: "use vibrant
  /// colors on top of materials").
  /// Sjednocení (audit): 1.8 → 1.5 -- vyšší sytost zesilovala zrno
  /// pozadí a barvila sklo do červena.
  static const double vibrancy = 1.5;

  /// Mírné zjasnění rozmazaného pozadí (součást vibrance).
  static const double brightness = 1.04;

  /// Neutrální výplň skla -- žádné akcentové tónování na chrome.
  /// Světlý režim: bílá ~12 %, tmavý: černá ~26 % + náznak bílé.
  static const double fillLight = 0.12;
  static const double fillDark = 0.30;
  static const double fillDarkWhiteHint = 0.04;

  /// Tlumení zrna v tmavém režimu: tenký bílý závoj navíc (jen tmavý
  /// režim, jen s neutrální výplní), aby se šum pozadí neprokreslil do skla.
  static const double frostDark = 0.03;

  /// Tónování barvou skladby -- JEN plochy přehrávače, jemně.
  static const double playerTint = 0.14;

  /// Clear varianta nad médii (obal) -- HIG: "If the underlying content is
  /// bright, consider adding a dark dimming layer of 35% opacity."
  static const double mediaDimming = 0.35;

  /// "Zvýrazněná" skleněná kapsle (vybraný tab / segment) = stejný materiál
  /// + bílá navíc.
  static const double emphasis = 0.08;

  // --- Hrana (specular) ---------------------------------------------------

  /// Vlasová hrana s přechodem (vlevo nahoře → vpravo dole) -- to z panelu
  /// dělá skutečné sklo. Žádné tlusté okraje ani záře.
  static const double edgeWidth = 0.8;
  static const double edgeAlphaStart = 0.45;
  static const double edgeAlphaEnd = 0.05;

  /// 1px vnitřní linka lesku u horní hrany.
  static const double topHighlightAlpha = 0.5;

  // --- Hloubka ------------------------------------------------------------

  /// Jediný měkký stín, jen na plovoucích prvcích (tab bar, mini
  /// přehrávač, návrhy, menu). Žádné vrstvené stíny.
  static const double shadowAlpha = 0.12;
  static const double shadowBlur = 28;
  static const double shadowOffsetY = 10;

  // --- Tvar ----------------------------------------------------------------

  /// Plynulé (squircle) rohy všude -- `AppShapes` (figma_squircle).
  /// Kapsle = poloměr >= polovina výšky.
  static const double smoothing = 0.6;

  // --- Rozměry (HIG Buttons / Accessibility) --------------------------------

  /// Minimální dotyková plocha: větší z obou systémů. HIG Buttons: "a
  /// button needs a hit region of at least 44x44 pt"
  /// (https://developer.apple.com/design/human-interface-guidelines/buttons);
  /// M3: touch target ≥ 48×48 dp.
  static const double minHitTarget = 48;

  /// Výška kapslí: tlačítka, vyhledávací pole, segmenty.
  static const double controlHeight = 44;
  static const double compactControlHeight = 36;

  /// Tab bar: plovoucí kapsle, 16 px od boků, 12 px nad safe area,
  /// výška 62. HIG Tab bars: "A tab bar floats above content at the bottom
  /// of the screen" (https://developer.apple.com/design/human-interface-guidelines/tab-bars).
  static const double tabBarHeight = 62;
  static const double floatingMargin = 16;
  static const double floatingBottomGap = 12;

  /// Sheety: velké horní rohy + úchyt. HIG Sheets: "Include a grabber in a
  /// resizable sheet" (https://developer.apple.com/design/human-interface-guidelines/sheets).
  static const double sheetRadius = 28;
  static const Size grabberSize = Size(36, 5);

  /// Panel návrhů / menu.
  static const double panelRadius = 14;

  // --- Stavy ---------------------------------------------------------------

  /// Stisk: jemné zmenšení + světlý závoj. HIG Buttons: "Always include a
  /// press state for a custom button."
  static const double pressedScale = 0.97;
  static const double pressedHighlight = 0.10;

  /// Nedostupný stav.
  static const double disabledOpacity = 0.38;

  /// Krátké stavové přechody (barva/průhlednost) -- pro pohyb polohy/tvaru
  /// vždy `Expressive.spatial*` pružiny.
  static const Duration stateDuration = Duration(milliseconds: 160);

  // --- Barvy ----------------------------------------------------------------

  /// Přepínač: HIG Toggles dovoluje místo zelené akcent appky ("you may use
  /// your app's accent color") -- mix s M3 Expressive proto volí tónový
  /// `colorScheme.primary`; zelená (`switchOnHig`) jen kde je potřeba
  /// systémový význam "zapnuto" nezávislý na barvě skladby.
  /// (https://developer.apple.com/design/human-interface-guidelines/toggles)
  static const Color switchOnHig = Color(0xFF34C759);

  /// Kontrast textu na skle: min. 4.5:1 do 17 pt, 3:1 větší/tučný
  /// (HIG Accessibility, https://developer.apple.com/design/human-interface-guidelines/accessibility).
  /// Na skle proto jen `onSurface` / `onSurfaceVariant`, žádné neonové akcenty.
  static const double minTextContrast = 4.5;
}

/// Vibrance: sytost + mírné zjasnění (luminance-preserving saturační matice
/// jako CSS `saturate()`). Skládá se s blurem do jednoho `BackdropFilter`.
ColorFilter vibrancyColorFilter({double saturation = GlassTokens.vibrancy, double brightness = GlassTokens.brightness}) {
  const lumR = 0.213, lumG = 0.715, lumB = 0.072;
  final inv = 1 - saturation;
  final ir = inv * lumR, ig = inv * lumG, ib = inv * lumB;
  final b = brightness;
  return ColorFilter.matrix(<double>[
    (ir + saturation) * b, ig * b, ib * b, 0, 0,
    ir * b, (ig + saturation) * b, ib * b, 0, 0,
    ir * b, ig * b, (ib + saturation) * b, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

/// M3 Expressive pohyb a tvary. Pružiny přesně dle AndroidX
/// `ExpressiveMotionTokens` (m3.material.io/styles/motion):
/// spatial (poloha, velikost, tvar, poloměr) smí překmitnout,
/// effects (barva, průhlednost) jsou kriticky tlumené.
class Expressive {
  const Expressive._();

  static final SpringCurve spatialDefault = SpringCurve(dampingRatio: 0.8, stiffness: 380);
  static final SpringCurve spatialFast = SpringCurve(dampingRatio: 0.6, stiffness: 800);
  static final SpringCurve spatialSlow = SpringCurve(dampingRatio: 0.8, stiffness: 200);
  static final SpringCurve effectsDefault = SpringCurve(dampingRatio: 1.0, stiffness: 1600);
  static final SpringCurve effectsFast = SpringCurve(dampingRatio: 1.0, stiffness: 3800);
  static final SpringCurve effectsSlow = SpringCurve(dampingRatio: 1.0, stiffness: 800);

  // Tvarová škála M3 (ShapeTokens.kt, dp) -- vykreslovaná jako squircle.
  static const double cornerNone = 0;
  static const double cornerExtraSmall = 4;
  static const double cornerSmall = 8;
  static const double cornerMedium = 12;
  static const double cornerLarge = 16;
  static const double cornerLargeIncreased = 20;
  static const double cornerExtraLarge = 28;
  static const double cornerExtraLargeIncreased = 32;
  static const double cornerExtraExtraLarge = 48;

  /// Morfologie stisku: kapsle při stisku zmáčkne rohy na tenhle podíl
  /// výšky (M3 Expressive "shape morph on press").
  static const double pressedCornerFraction = 0.28;

  /// Vnitřní rohy spojené skupiny tlačítek (M3 connected button group).
  static const double groupInnerCorner = cornerSmall;

  /// Vnitřní lesk tónové pilulky -- jen pro případné tónové kapsle mimo
  /// vybraný stav (vybraný stav je neutrální, viz pravidla výš).
  static const double selectedPillHighlightAlpha = 0.25;
}

/// Pohybové aliasy -- JEDINÉ, co obrazovky používají pro animace.
/// Pravidlo: žádné holé `Curves.*` ani ručně zadané délky mimo
/// `widgets/app_background.dart` (to má vlastní hodiny). Délka animace =
/// `Motion.x.duration` (čas ustálení pružiny).
class Motion {
  const Motion._();

  /// Příchod / změna polohy, velikosti, tvaru (smí mírně překmitnout).
  static SpringCurve get enter => Expressive.spatialDefault;

  /// Odchod -- rychlejší, bez výrazného překmitu.
  static SpringCurve get exit => Expressive.spatialFast;

  /// Změna stavu: barva, průhlednost, výplň (bez překmitu).
  static SpringCurve get state => Expressive.effectsDefault;

  /// Odezva na dotek (zmáčknutí rohů, posun palce přepínače) -- rychlá
  /// pružina s mírným překmitem.
  static SpringCurve get press => Expressive.spatialFast;
}

/// Pružina (`SpringDescription`, hmotnost 1) jako `Curve` -- aby šla použít
/// ve všech `Animated*` widgetech. `duration` je čas do ustálení (±0.1 %),
/// používej ho jako `duration` animace.
class SpringCurve extends Curve {
  SpringCurve({required this.dampingRatio, required this.stiffness})
      : _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: stiffness, ratio: dampingRatio) {
    duration = Duration(microseconds: (_settleTime() * 1e6).round());
  }

  final double dampingRatio;
  final double stiffness;
  final SpringDescription _spring;
  late final Duration duration;

  double _settleTime() {
    final sim = SpringSimulation(_spring, 0, 1, 0);
    var t = 0.0;
    var settledSince = -1.0;
    while (t < 3) {
      final done = (sim.x(t) - 1).abs() < 0.001 && sim.dx(t).abs() < 0.01;
      if (done && settledSince < 0) settledSince = t;
      if (!done) settledSince = -1;
      if (settledSince >= 0 && t - settledSince > 0.05) return math.max(settledSince, 0.05);
      t += 1 / 240;
    }
    return 3;
  }

  @override
  double transformInternal(double t) {
    final seconds = t * duration.inMicroseconds / 1e6;
    return SpringSimulation(_spring, 0, 1, 0).x(seconds);
  }
}
