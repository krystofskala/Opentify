import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';
import 'config.dart';

// Veřejné repo, žádné přihlášení ani údaje o uživateli -- jen statický soubor.
// Repo z buildu (`UPDATE_REPO`, v GitHub Actions to vlastní); bez něj žádné
// aktualizace (vlastní kopie projektu nehledá verze u někoho jiného).
const _latest = 'https://github.com/${AppConfig.updateRepo}/releases/download/android-latest';
const _channel = MethodChannel('app.opentify/update');

final bool supported = Platform.isAndroid && AppConfig.updateRepo.isNotEmpty;

Future<AppUpdate?> check() async {
  if (!supported) return null;
  try {
    final res = await http.get(Uri.parse('$_latest/version.json')).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = (json['build'] as num).toInt();
    final current = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    if (latest <= current) return null;
    return AppUpdate(
      build: latest,
      version: json['version'] as String? ?? '$latest',
      apkUrl: json['apk'] as String? ?? '$_latest/Opentify.apk',
    );
  } catch (_) {
    return null;
  }
}

Future<void> install(AppUpdate update, {void Function(double progress)? onProgress}) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
  await dir.create(recursive: true);
  final file = File('${dir.path}/Opentify.apk');
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(update.apkUrl)));
    if (res.statusCode != 200) throw HttpException('APK: HTTP ${res.statusCode}');
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
  } finally {
    client.close();
  }
  // MainActivity: FileProvider + ACTION_VIEW, Android ukáže instalaci (napoprvé
  // i povolení "Instalovat z tohoto zdroje").
  await _channel.invokeMethod<void>('installApk', {'path': file.path});
}
