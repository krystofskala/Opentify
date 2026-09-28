import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/safe_area_insets.dart';

/// Vstupní bod. Primárně cílíme na `flutter run -d chrome` pro rychlé
/// testování proti lokálnímu backendu (viz README.md v tomhle adresáři pro
/// `--dart-define` proměnné base URL) -- `ProviderScope` je jediné, co main
/// potřebuje, veškerá závislost na backendu žije v `state/providers.dart`.
void main() {
  runApp(const ProviderScope(child: WebSafeAreaInsets(child: OpentifyApp())));
}
