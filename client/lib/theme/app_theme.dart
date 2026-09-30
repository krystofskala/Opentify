import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'accent_color.dart' show isAchromatic;
import 'design_tokens.dart';
import 'shapes.dart';

/// Sdílený motiv appky -- nahrazuje trojřádkový inline `ThemeData(...)` v
/// `app.dart`, který nastavoval jen `colorSchemeSeed`. Bez `textTheme`/
/// `appBarTheme`/`cardTheme` si každá obrazovka řešila vzhled (poloměry,
/// styl AppBaru, "elevaci") sama a nezávisle na ostatních -- to byl hlavní
/// zdroj vizuální nekonzistence napříč appkou (viz plán "design consistency
/// + player feature parity"). Používá se stejně pro `theme`/`darkTheme` v
/// `app.dart`, jen s jiným `brightness`.
ThemeData buildAppTheme({required Color seed, required Brightness brightness}) {
  // Černobílý/šedý seed: `tonalSpot` by mu přidal sytost v odstínu šedé
  // (≈ červená) -- neutrální monochromatické schéma místo toho.
  final base = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: isAchromatic(seed) ? DynamicSchemeVariant.monochrome : DynamicSchemeVariant.tonalSpot,
    ),
    useMaterial3: true,
  );
  final colorScheme = base.colorScheme;

  // Skutečné pozadí appky teď kreslí `AppBackground` (gradient + zrno) pod
  // celým `MaterialApp.router`em (viz `app.dart`'s `builder`) -- `Scaffold`y
  // proto zůstávají průhledné, ať skrz prosvítá. Dřívější pokusy (plochý
  // `colorScheme.surface`, pak ručně počítaná šedá) řešily jen "jak tmavá
  // barva", ne že jediná plochá barva sama o sobě vypadá mrtvě/plošně --
  // gradient+zrno je skutečná oprava, tohle pole samo teď dělá jen "nekrýt".
  //
  // Karty/`surfaceContainerHigh` pořád potřebují vlastní neprůhlednou barvu
  // (jinak by text nad gradientem nebyl čitelný) -- tón počítáme ručně stejně
  // jako dřív pozadí, jen teď jako JEDINÝ účel: zaručený kontrast karty vůči
  // gradientu pod ní, nezávisle na tom, jak M3 zrovna tónuje daný seed.
  final surfaceHue = HSLColor.fromColor(colorScheme.surface);
  final darkCardColor = surfaceHue.withLightness(0.24).toColor();

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: _buildTextTheme(base.textTheme),
    // Tenčí Material Symbols (variabilní font) -- vedle vlasových skleněných
    // hran působí výchozí váha 400 těžce. `fill: 1` jen pro vybraný/aktivní
    // stav, jinak obrys (viz pravidla v `theme/glass_tokens.dart`).
    iconTheme: IconThemeData(color: colorScheme.onSurface, weight: 300, opticalSize: 24, grade: 0),
    primaryIconTheme: IconThemeData(color: colorScheme.onPrimary, weight: 300, opticalSize: 24, grade: 0),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      // Emphasized nadpis sekce (M3 Expressive) -- velký, těžký, úzký.
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontFamily: 'Nunito',
        fontSize: 28,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.8,
        color: colorScheme.onSurface,
      ),
      iconTheme: IconThemeData(color: colorScheme.onSurface, weight: 300, opticalSize: 24, grade: 0),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: brightness == Brightness.dark ? darkCardColor : colorScheme.surfaceContainerHigh,
      shape: AppShapes.md,
      clipBehavior: Clip.antiAlias,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    // "Squircle" (kontinuální zaoblení, ne kruhový oblouk) na všech
    // interaktivních plochách -- PixelPlayerovo `AbsoluteSmoothCornerShape`
    // přes `figma_squircle` (viz theme/shapes.dart), jeden z hlavních
    // vizuálních signálů, že appka vypadá jako PixelPlay a ne jako obecná
    // Material appka s obyčejnými zaoblenými rohy.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(AppShapes.pill)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(AppShapes.pill))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(AppShapes.pill))),
    textButtonTheme: TextButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(AppShapes.pill))),
    // Čipy = obsahové ovládání -> M3 Expressive tónové kontejnery ze seedu,
    // žádné sklo (HIG Materials) a žádná šeď (viz `theme/glass_tokens.dart`).
    chipTheme: ChipThemeData(
      shape: AppShapes.pill,
      side: BorderSide.none,
      backgroundColor: colorScheme.secondaryContainer,
      selectedColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(color: colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600),
      iconTheme: IconThemeData(color: colorScheme.onSecondaryContainer, size: 18, weight: 300, grade: 0),
    ),
    // Hlášky jako tmavá skleněná kapsle v obou režimech (Apple styl) --
    // v tmavém režimu dřív svítila bílá `inverseSurface` jako cizí prvek.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xEB2A2A30)
          : colorScheme.inverseSurface.withValues(alpha: 0.92),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        fontFamily: 'Nunito',
        fontWeight: FontWeight.w600,
        color: brightness == Brightness.dark ? Colors.white : colorScheme.onInverseSurface,
      ),
      actionTextColor: brightness == Brightness.dark ? colorScheme.primaryFixedDim : colorScheme.inversePrimary,
      shape: const StadiumBorder(),
      elevation: 0,
    ),
    // Jeden jezdec v celé appce (hlasitost, nastavení skla): tenká dráha
    // a bílý kulatý úchyt jako v iOS, bez materiálového "halo".
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: colorScheme.primary,
      inactiveTrackColor: colorScheme.onSurface.withValues(alpha: 0.15),
      thumbColor: Colors.white,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11, elevation: 3, pressedElevation: 4),
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl))),
    ),
    // Dialogy ve stejném tónu jako skleněné panely (ne M3 fialovo-šedý
    // `surfaceContainerHigh` s tónováním).
    dialogTheme: DialogThemeData(
      shape: AppShapes.lg,
      backgroundColor: brightness == Brightness.dark ? const Color(0xF51E1E22) : const Color(0xF5F7F7FA),
      surfaceTintColor: Colors.transparent,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontFamily: 'Nunito',
        fontSize: 22,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
        color: colorScheme.onSurface,
      ),
    ),
    // Přechody mezi obrazovkami: na iOS nativní (gesto zpět od okraje), jinde
    // jemné prolnutí s krátkým posunem vzhůru. Výchozí "zoom" přechod na webu
    // (Chrome na PC) trhal -- snímkuje celé stránky (živě nahlášeno).
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: _SoftRisePageTransitionsBuilder(),
        TargetPlatform.windows: _SoftRisePageTransitionsBuilder(),
        TargetPlatform.macOS: _SoftRisePageTransitionsBuilder(),
        TargetPlatform.linux: _SoftRisePageTransitionsBuilder(),
        TargetPlatform.fuchsia: _SoftRisePageTransitionsBuilder(),
      },
    ),
  );
}

/// Nová obrazovka se prolne a dojede o 24 px zespodu (ease-out), stará pod
/// ní jen lehce ztmavne -- žádné snímkování ani škálování celé stránky, takže
/// je to plynulé i v prohlížeči na PC.
class _SoftRisePageTransitionsBuilder extends PageTransitionsBuilder {
  const _SoftRisePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final under = CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.6).animate(under),
      child: FadeTransition(
        opacity: enter,
        child: AnimatedBuilder(
          animation: enter,
          builder: (context, child) => Transform.translate(offset: Offset(0, 24 * (1 - enter.value)), child: child),
          child: child,
        ),
      ),
    );
  }
}

/// Jednotný zaoblený typeface (Nunito, viz `pubspec.yaml`) napříč celou
/// appkou -- PixelPlay používá jedno "Google Sans Flex" písmo se stejnou
/// rolí (přátelský, ne systémový/výchozí vzhled), Nunito je nejbližší
/// veřejně bundlovatelná OFL náhrada se srovnatelnou váhovou škálou.
/// Nadpisy dostávají mírně záporný `letterSpacing`, stejně jako PixelPlayerův
/// mini-player titulek.
TextTheme _buildTextTheme(TextTheme base) {
  // M3 Expressive "emphasized" typografie: nadpisy větší, těžší a s
  // užším prostrkáním -- editoriální hierarchie; tělo textu beze změny.
  return base.apply(fontFamily: 'Nunito').copyWith(
        displaySmall:
            base.displaySmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w900, letterSpacing: -1.0),
        headlineLarge:
            base.headlineLarge?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w900, letterSpacing: -0.8),
        headlineMedium:
            base.headlineMedium?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w900, letterSpacing: -0.6),
        headlineSmall:
            base.headlineSmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w800, letterSpacing: -0.5),
        titleLarge: base.titleLarge
            ?.copyWith(fontFamily: 'Nunito', fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -0.5),
        titleMedium: base.titleMedium
            ?.copyWith(fontFamily: 'Nunito', fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        titleSmall: base.titleSmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w700),
        bodyLarge: base.bodyLarge?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w600),
        bodyMedium: base.bodyMedium?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w500),
        labelLarge: base.labelLarge?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w700),
      );
}
