{{flutter_js}}
{{flutter_build_config}}

// No service worker: in Home Assistant's sidebar a cached old version
// would outlive add-on updates.
_flutter.loader.load({
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine();
    await appRunner.runApp();
    document.getElementById('splash')?.remove();
  },
});
