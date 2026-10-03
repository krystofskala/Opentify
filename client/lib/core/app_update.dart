import 'app_update_stub.dart' if (dart.library.io) 'app_update_io.dart' as impl;

/// Novější Android verze z GitHub vydání `android-latest` (CI ho přepisuje
/// při každém Android buildu, viz `.github/workflows/android.yml`).
class AppUpdate {
  const AppUpdate({required this.build, required this.version, required this.apkUrl});

  final int build;
  final String version;
  final String apkUrl;
}

/// Jen na Androidu -- iOS aktualizuje SideStore, web je vždy aktuální.
bool get appUpdatesSupported => impl.supported;

/// Novější verze, nebo null (žádná / jiná platforma / bez sítě).
Future<AppUpdate?> checkForAppUpdate() => impl.check();

/// Stáhne APK a otevře systémovou instalaci (Android se zeptá sám).
Future<void> installAppUpdate(AppUpdate update, {void Function(double progress)? onProgress}) =>
    impl.install(update, onProgress: onProgress);
