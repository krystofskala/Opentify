import 'dart:io' show Platform;

import 'package:just_audio_media_kit/just_audio_media_kit.dart';

void initDesktopAudio() {
  if (Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: false, android: false, iOS: false, macOS: false);
  }
}
