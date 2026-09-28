import 'package:flutter/material.dart';

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
  final base = ThemeData(colorSchemeSeed: seed, brightness: brightness, useMaterial3: true);
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
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colorScheme.inverseSurface.withValues(alpha: 0.9),
      shape: const StadiumBorder(),
      elevation: 0,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl))),
    ),
    dialogTheme: DialogThemeData(shape: AppShapes.lg),
  );
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
  return base
      .apply(fontFamily: 'Nunito')
      .copyWith(
        displaySmall: base.displaySmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w900, letterSpacing: -1.0),
        headlineLarge: base.headlineLarge?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w900, letterSpacing: -0.8),
        headlineMedium: base.headlineMedium?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w900, letterSpacing: -0.6),
        headlineSmall: base.headlineSmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w800, letterSpacing: -0.5),
        titleLarge: base.titleLarge?.copyWith(fontFamily: 'Nunito', fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -0.5),
        titleMedium: base.titleMedium?.copyWith(fontFamily: 'Nunito', fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        titleSmall: base.titleSmall?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w700),
        bodyLarge: base.bodyLarge?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w600),
        bodyMedium: base.bodyMedium?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w500),
        labelLarge: base.labelLarge?.copyWith(fontFamily: 'Nunito', fontWeight: FontWeight.w700),
      );
}
