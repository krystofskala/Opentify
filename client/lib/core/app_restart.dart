import 'package:flutter/foundation.dart';

/// Restart stavu appky v nativní verzi (web místo toho znovu načte stránku):
/// `main.dart` drží `ProviderScope` s klíčem podle téhle hodnoty -- zvýšení
/// zahodí všechny providery (data profilu, přehrávač, spojení) a začne
/// znovu. Přepnutí profilu a odhlášení dřív nativně nedělalo nic (živě:
/// přepnutí na tátu zůstalo na mém profilu).
final ValueNotifier<int> appRestartTick = ValueNotifier<int>(0);

void restartApp() => appRestartTick.value++;
