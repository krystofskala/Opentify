/// Sdílená škála zaoblení -- nahrazuje dosavadní ad hoc
/// `BorderRadius.circular(n)` s hodnotami 8/10/12/14/16/18/20/22/24/28/100
/// roztroušenými po jednotlivých obrazovkách (viz konzistenční audit).
/// Konvence: náhledový obrázek dlaždice bere o úroveň menší poloměr než
/// dlaždice samotná (typicky `tile - 4`, ne níž než [xs]) -- stejný poměr
/// jako PixelPlayerův řádek(22)/náhled(10).
class AppRadii {
  const AppRadii._();

  static const double xs = 8; // odznaky, čipy, malé náhledy
  static const double sm = 12; // náhledy skladeb v dlaždicích
  static const double md = 16; // standardní karty/dlaždice/tlačítka
  static const double lg = 20; // skleněné kontejnery, hlavičky sekcí
  static const double xl = 24; // velké obaly, horní rohy sheetů, hlavičky detailu
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
