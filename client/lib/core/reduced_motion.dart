import 'reduced_motion_stub.dart' if (dart.library.js_interop) 'reduced_motion_web.dart' as impl;

/// `prefers-reduced-motion` z prohlížeče -- Flutter web ho do
/// `MediaQuery.disableAnimations` spolehlivě nepropisuje.
bool systemPrefersReducedMotion() => impl.prefersReducedMotion();
