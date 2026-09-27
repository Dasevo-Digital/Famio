import 'package:flutter/services.dart';

/// Which Famio this build is: the released app for the family or the
/// development build (`--dart-define=FAMIO_ENV=dev`), which lives next to it
/// with its own name, data, keychain entry and server.
abstract final class AppEnv {
  static const name = String.fromEnvironment('FAMIO_ENV', defaultValue: 'prod');
  /// Also the Android build variant (`--flavor dev`).
  static const isDev = name == 'dev' || appFlavor == 'dev';
  static const appName = isDev ? 'Famio Dev' : 'Famio';

  /// HTTPS port tried first when connecting; the development server runs
  /// beside the family's one on its own ports.
  static const tlsPort = isDev ? 8776 : 8766;
  static const httpPort = isDev ? 8775 : 8765;
}
