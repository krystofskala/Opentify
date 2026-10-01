import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'config.dart';
import 'share_link_stub.dart'
    if (dart.library.js_interop) 'share_link_web.dart'
    if (dart.library.io) 'share_link_io.dart' as impl;

/// Univerzální odkaz na skladbu/album (song.link / album.link) -- kamarád
/// ho otevře v jakékoliv hudební appce. Viz backend app/routes/share.py.
class ShareLink {
  const ShareLink({required this.url, required this.title, this.artistName, this.spotifySearchUrl});

  /// `null` u vlastní hudby (tátův Kontrast) -- venku neexistuje.
  final String? url;
  final String title;
  final String? artistName;

  /// Když Spotify ID nemáme, song.link Spotify často nenabídne -- tak aspoň
  /// vyhledání "název interpret" přímo ve Spotify.
  final String? spotifySearchUrl;

  String get _name => artistName == null ? title : '$title – $artistName';

  /// Text ke sdílení (odkaz jde zvlášť jako url).
  String get text => spotifySearchUrl == null ? _name : '$_name\nSpotify: $spotifySearchUrl';

  /// Do schránky (na PC): univerzální odkaz + případně řádek pro Spotify.
  String get clipboardText => spotifySearchUrl == null ? (url ?? '') : '${url ?? ''}\nSpotify: $spotifySearchUrl';
}

typedef ShareTarget = ({String kind, String id}); // kind: recordings | releases

/// Načte se hned při otevření menu -- iOS Safari dovolí systémové sdílení
/// jen v přímé reakci na klepnutí, ne až po síťovém dotazu.
final shareLinkProvider = FutureProvider.autoDispose.family<ShareLink, ShareTarget>((ref, target) async {
  final json = await ref.watch(apiClientProvider).getJson('/share/${target.kind}/${target.id}');
  return ShareLink(
    url: json['url'] as String?,
    title: json['title'] as String,
    artistName: json['artistName'] as String?,
    spotifySearchUrl: json['spotifySearchUrl'] as String?,
  );
});

enum ShareOutcome { shared, copied, failed }

/// Telefon: systémová nabídka sdílení (Zprávy, WhatsApp...). Počítač (nebo
/// když sdílení není k dispozici): zkopírovat odkaz do schránky.
Future<ShareOutcome> shareLink(ShareLink link) async {
  final url = link.url;
  if (url == null) return ShareOutcome.failed;
  if (await impl.nativeShare(link.text, url)) return ShareOutcome.shared;
  try {
    await Clipboard.setData(ClipboardData(text: link.clipboardText));
    return ShareOutcome.copied;
  } catch (_) {
    return ShareOutcome.failed;
  }
}

/// „Poslat v Opentify": odkaz, který otevře skladbu/album přímo v Opentify
/// (pro lidi se sdíleným Opentify). Skládá se bez sítě -- iPhone ho sdílí
/// hned v rámci klepnutí.
Future<ShareOutcome> shareInOpentify({required String path, required String title, String? artistName}) async {
  final url = '${AppConfig.sharedOrigin}/#$path';
  final text = artistName == null ? '$title (Opentify)' : '$title – $artistName (Opentify)';
  if (await impl.nativeShare(text, url)) return ShareOutcome.shared;
  try {
    await Clipboard.setData(ClipboardData(text: url));
    return ShareOutcome.copied;
  } catch (_) {
    return ShareOutcome.failed;
  }
}

Future<void> shareInOpentifyWithToast(
  ScaffoldMessengerState? messenger, {
  required String path,
  required String title,
  String? artistName,
}) async {
  final outcome = await shareInOpentify(path: path, title: title, artistName: artistName);
  if (outcome == ShareOutcome.copied) {
    messenger?.showSnackBar(const SnackBar(content: Text('Odkaz do Opentify zkopírován'), duration: Duration(seconds: 2)));
  }
}
