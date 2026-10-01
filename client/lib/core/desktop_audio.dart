import 'desktop_audio_stub.dart' if (dart.library.io) 'desktop_audio_io.dart' as impl;

/// Windows: just_audio nemá vlastní přehrávač -- zapojí se media_kit (libmpv).
/// Jinde nic (web by media_kit kvůli dart:ffi ani nezkompiloval).
void initDesktopAudio() => impl.initDesktopAudio();
