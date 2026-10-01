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
