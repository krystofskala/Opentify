import 'package:share_plus/share_plus.dart';

/// Nativní appka: systémové sdílení (iOS share sheet).
Future<bool> nativeShare(String text, String url) async {
  await Share.share('$text\n$url');
  return true;
}
