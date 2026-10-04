import 'config.dart';
import 'app_restart.dart';

String? joinCodeFromUrl() => null;
void clearJoinFromUrl() {}
void reloadPage() => restartApp();
String appOrigin() {
  const origin = String.fromEnvironment('APP_ORIGIN');
  return origin.isNotEmpty ? origin : AppConfig.sharedOrigin;
}
