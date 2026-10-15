{{flutter_js}}
{{flutter_build_config}}

// No service worker: in Home Assistant's sidebar a cached old version
// would outlive add-on updates.
_flutter.loader.load({
  onEntrypointLoaded: async (engineInitializer) => {
    // Emoji and other fallback fonts from the Famio server, not from Google
    // (see tool/build_web.sh).
    const appRunner = await engineInitializer.initializeEngine({
      fontFallbackBaseUrl: 'fonts/',
    });
    await appRunner.runApp();
    document.getElementById('splash')?.remove();
  },
});
