import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which Famio this build is: the released app for the family or the
/// development build (`--dart-define=FAMIO_ENV=dev`), which lives next to it
/// with its own name, data, keychain entry and server.
abstract final class AppEnv {
  static const name = String.fromEnvironment('FAMIO_ENV', defaultValue: 'prod');

  /// Integration tests against throwaway servers
  /// (`tool/integration_tests.sh`): a development build with its own
  /// keychain entry, so a test never replaces the session of "Famio Dev".
  static const isE2e = name == 'e2e';

  /// Several throwaway-server runs side by side
  /// (`--dart-define=FAMIO_E2E_SLOT=2`), each with its own bundle id and
  /// keychain entry.
  static const _e2eSlot = String.fromEnvironment('FAMIO_E2E_SLOT');

  /// Also the Android build variant (`--flavor dev`).
  static const isDev = name == 'dev' || isE2e || appFlavor == 'dev';

  /// The app's entry in the system keychain. On macOS all builds share the
  /// login keychain, so each variant needs its own.
  static const vaultEntry = isE2e
      ? 'famio-e2e$_e2eSlot'
      : isDev
      ? 'famio-dev'
      : 'famio';
  static const appName = isDev ? 'Famio Dev' : 'Famio';

  /// HTTPS port tried first when connecting; the development server runs
  /// beside the family's one on its own ports.
  static const tlsPort = isE2e
      ? _e2eTlsPort
      : isDev
      ? 8776
      : 8766;

  /// Tests against a throwaway server name its HTTPS port
  /// (`--dart-define=FAMIO_E2E_TLS_PORT`, tool/integration_tests.sh), so that
  /// "Jetzt verschlüsseln" never reaches the development server on 8776.
  static const _e2eTlsPort = int.fromEnvironment(
    'FAMIO_E2E_TLS_PORT',
    defaultValue: 8776,
  );
  static const httpPort = isDev ? 8775 : 8765;

  /// A build for an app store (`--dart-define=FAMIO_STORE=true`): Apple and
  /// Google only allow tips through their own payment, so the Ko-fi link
  /// stays out.
  static const storeBuild = bool.fromEnvironment('FAMIO_STORE');

  /// Where the family can support Famio's development.
  static const supportUrl = 'https://ko-fi.com/superkuh86';

  /// Famio's privacy information, also named in the app stores.
  static const privacyUrl =
      'https://github.com/Dasevo-Digital/Famio/blob/main/docs/datenschutz.md';

  /// [privacyUrl] in the app's [language], where there is a translation
  /// (#502).
  static String privacyUrlFor(String language) => switch (language) {
    'en' || 'es' => privacyUrl.replaceFirst('.md', '.$language.md'),
    _ => privacyUrl,
  };

  /// iPhone and iPad: Apple's rules keep other platforms and their stores
  /// out of what the app shows (App Review 2.3.10).
  static bool get onIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}
