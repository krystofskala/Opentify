import 'dart:typed_data';

import 'recorder_bridge.dart';

Future<String> startRecording() async => throw const RecorderException('unsupported');

Future<Uint8List> recordingSnapshot() async => Uint8List(0);

Future<void> stopRecording() async {}
