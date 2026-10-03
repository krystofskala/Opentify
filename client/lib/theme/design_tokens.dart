/// Sdílená škála zaoblení -- nahrazuje dosavadní ad hoc
/// `BorderRadius.circular(n)` s hodnotami 8/10/12/14/16/18/20/22/24/28/100
/// roztroušenými po jednotlivých obrazovkách (viz konzistenční audit).
/// Konvence: náhledový obrázek dlaždice bere o úroveň menší poloměr než
/// dlaždice samotná (typicky `tile - 4`, ne níž než [xs]) -- stejný poměr
/// jako PixelPlayerův řádek(22)/náhled(10).
/// Jediná škála poloměrů = M3 Expressive (`Expressive.corner*` v
/// glass_tokens.dart): 8 / 12 / 16 / 20 / 28. Jiné hodnoty (14, 22, 24) se
/// nepoužívají -- dřív se dvě škály míchaly (design audit).
class AppRadii {
  const AppRadii._();

  static const double xs = 8; // = cornerSmall: odznaky, čipy, malé náhledy
  static const double sm = 12; // = cornerMedium: náhledy, karty alb a playlistů
  static const double md = 16; // = cornerLarge: dlaždice, tlačítka, panely
  static const double lg = 20; // = cornerLargeIncreased: skleněné kontejnery
  static const double xl = 28; // = cornerExtraLarge: velké obaly, sheety, hlavičky detailu
  static const double pill = 999; // aktivní/hrající morph cíl, plně kulaté ovladače
  static const double xxs = 4; // tenké pruhy (průběh, úchyty)
}

/// Škála velikostí písma mimo `textTheme` (přehrávač, karty ke sdílení,
/// odznaky) -- jediný zdroj čísel, ať se velikosti nerozjíždějí. Tam, kde to
/// jde, má přednost `Theme.of(context).textTheme`.
class AppFontSize {
  const AppFontSize._();

  static const double micro = 10; // odznaky na kartách
  static const double tiny = 11; // popisky tab baru, štítky
  static const double caption = 12; // vedlejší řádek (interpret, čas)
  static const double small = 13;
  static const double body = 14;
  static const double bodyLarge = 15;
  static const double lead = 16; // text písně, karty
  static const double title = 17; // název skladby v přehrávači
  static const double titleLarge = 18;
  static const double heading = 22;
  static const double display = 24; // aktivní řádek textu písně
  static const double hero = 26; // velký název (přehrávač, karta ke sdílení)
  static const double large = 28;
  static const double xl = 30;
  static const double xxl = 34; // číslo na obalu mixu
}

/// Sdílená škála rozestupů -- nahrazuje ad hoc `EdgeInsets`/`SizedBox`
/// hodnoty roztroušené po jednotlivých obrazovkách.
class AppSpacing {
  const AppSpacing._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}
