{{flutter_js}}
{{flutter_build_config}}

// Flutter runs inside the full-screen #app element (index.html). Safe-area
// insets are passed into MediaQuery by lib/core/safe_area_insets.dart, since
// Flutter web doesn't report them itself.
_flutter.loader.load({
  // CanvasKit from our own server (build/web/canvaskit/), not gstatic.com:
  // 13 Oct a firm network held the ~7 MB download for minutes and the app
  // stayed on the index.html background.
  config: { canvasKitBaseUrl: 'canvaskit/' },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      hostElement: document.getElementById('app'),
    });
    await appRunner.runApp();
  },
});
