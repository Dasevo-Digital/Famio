import 'package:famio_shared/famio_shared.dart';

/// Messages of the client that the app shows. German; an app translates
/// them through [sharedTexts] (keys `Client|<German text>`).
abstract final class ClientTexts {
  static String _t(String german, [Map<String, Object?> args = const {}]) =>
      sharedText('Client|$german', german, args);

  static String get googleCanceled => _t('Anmeldung bei Google abgebrochen');

  static String googleFailed(Object? error) =>
      _t('Google-Anmeldung fehlgeschlagen ({error})', {'error': error});

  static String get googleNotCompleted =>
      _t('Die Google-Anmeldung wurde nicht abgeschlossen');

  static String get googleConnected => _t('Mit Google verbunden');

  static String get googleNotConnected => _t('Nicht verbunden');

  static String get googleCloseWindow =>
      _t('Du kannst dieses Fenster schließen und zu Famio zurückkehren.');

  static String get googleInApp => _t(
    'Google-Kalender bitte in der Famio-App am Computer oder Handy '
    'verbinden.',
  );

  static String get tlsRejected => _t(
    'Das Zertifikat des Servers passt nicht zum bestätigten. Wurde der '
    'Server neu eingerichtet? Dann die Adresse neu eingeben und den '
    'Fingerabdruck mit dem Server-Log vergleichen.',
  );

  static String get tlsFailed => _t('Verschlüsselte Verbindung fehlgeschlagen');

  static String get notFamio => _t('Das ist kein Famio-Server');

  static String uploadFailed(Object? error) =>
      _t('Upload fehlgeschlagen ({error})', {'error': error});

  static String unreachable(Object? error) =>
      _t('Server nicht erreichbar ({error})', {'error': error});

  static String unexpectedAnswer(int status) =>
      _t('Unerwartete Antwort vom Server (HTTP {status})', {'status': status});

  static String error(int status) => _t('Fehler {status}', {'status': status});

  /// Every message once, for the translation check.
  static List<String> all() => [
    googleCanceled,
    googleFailed(''),
    googleNotCompleted,
    googleConnected,
    googleNotConnected,
    googleCloseWindow,
    googleInApp,
    tlsRejected,
    tlsFailed,
    notFamio,
    uploadFailed(''),
    unreachable(''),
    unexpectedAnswer(0),
    error(0),
  ];
}
