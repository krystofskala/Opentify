import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'share_link_stub.dart' if (dart.library.js_interop) 'share_link_web.dart' as impl;

/// Univerzální odkaz na skladbu/album (song.link / album.link) -- kamarád
/// ho otevře v jakékoliv hudební appce. Viz backend app/routes/share.py.
class ShareLink {
  const ShareLink({required this.url, required this.title, this.artistName});

  final String url;
  final String title;
  final String? artistName;

  String get text => artistName == null ? title : '$title – $artistName';
}

typedef ShareTarget = ({String kind, String id}); // kind: recordings | releases

/// Načte se hned při otevření menu -- iOS Safari dovolí systémové sdílení
/// jen v přímé reakci na klepnutí, ne až po síťovém dotazu.
final shareLinkProvider = FutureProvider.autoDispose.family<ShareLink, ShareTarget>((ref, target) async {
  final json = await ref.watch(apiClientProvider).getJson('/share/${target.kind}/${target.id}');
  return ShareLink(
    url: json['url'] as String,
    title: json['title'] as String,
    artistName: json['artistName'] as String?,
  );
});

enum ShareOutcome { shared, copied, failed }

/// Telefon: systémová nabídka sdílení (Zprávy, WhatsApp...). Počítač (nebo
/// když sdílení není k dispozici): zkopírovat odkaz do schránky.
Future<ShareOutcome> shareLink(ShareLink link) async {
  if (await impl.nativeShare(link.text, link.url)) return ShareOutcome.shared;
  try {
    await Clipboard.setData(ClipboardData(text: link.url));
    return ShareOutcome.copied;
  } catch (_) {
    return ShareOutcome.failed;
  }
}
