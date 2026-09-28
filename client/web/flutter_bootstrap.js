{{flutter_js}}
{{flutter_build_config}}

// Flutter runs inside #app (index.html), which is inset by the iPhone safe
// areas: Flutter web does not report safe-area padding itself, so without
// this the app would draw under the status bar / home indicator once the
// status bar is translucent.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      hostElement: document.getElementById('app'),
    });
    await appRunner.runApp();
  },
});
