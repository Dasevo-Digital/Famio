/// Passkeys need the browser's WebAuthn; the installed apps do not offer
/// them yet.
bool get passkeysSupported => false;

Future<Map<String, Object?>?> createPasskey(
  Map<String, Object?> options,
) async => null;

Future<Map<String, Object?>?> usePasskey(Map<String, Object?> options) async =>
    null;
