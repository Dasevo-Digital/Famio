import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Public half of the Famio release key (Ed25519, raw 32 bytes, base64).
/// `tool/sign_release.sh` signs every release's `SHA256SUMS.txt` with the
/// private half, which only exists in the maintainer's keychain. A Famio
/// server offers an app package, and an app installs it, only if the
/// signature fits, so not even a taken-over server can push other code.
///
/// Only an end-to-end test build passes another key
/// (`--dart-define=FAMIO_RELEASE_KEY=…`); it is fixed at build time, a
/// running app or server cannot change it.
const famioReleaseKey = String.fromEnvironment(
  'FAMIO_RELEASE_KEY',
  defaultValue: 'CZPDczidQHLcY2jI4wTDi46p3tjelZzIISk/R1UYjcs=',
);

/// The app packages a Famio server hands out to its apps.
enum AppPlatform {
  android,
  windows,
  linux;

  /// The file of [version] in a release.
  String fileName(String version) => switch (this) {
    android => 'Famio-$version-android.apk',
    windows => 'Famio-$version-windows-x86_64.zip',
    linux => 'Famio-$version-linux-x86_64.tar.gz',
  };

  static AppPlatform? byName(String? name) =>
      values.where((p) => p.name == name).firstOrNull;
}

/// The lines of a `SHA256SUMS.txt` (`<hex>  <file>`) as file → hash.
Map<String, String> parseChecksums(String sums) => {
  for (final line in const LineSplitter().convert(sums))
    if (RegExp(r'^([0-9a-f]{64})\s+\*?(\S.*)$').firstMatch(line.trim())
        case final m?)
      m[2]!: m[1]!,
};

/// Whether [signature] (base64, the content of `SHA256SUMS.txt.sig`) is
/// the release key's signature of exactly [sums].
Future<bool> verifyReleaseSignature(
  String sums,
  String signature, {
  String publicKey = famioReleaseKey,
}) async {
  try {
    final bytes = base64.decode(signature.trim());
    if (bytes.length != 64) return false;
    return await Ed25519().verify(
      utf8.encode(sums),
      signature: Signature(
        bytes,
        publicKey: SimplePublicKey(
          base64.decode(publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// The SHA-256 [file] must have according to a signed release: null if
/// the signature does not fit or the file is not listed.
Future<String?> signedChecksum(
  String sums,
  String signature,
  String file, {
  String publicKey = famioReleaseKey,
}) async {
  if (!await verifyReleaseSignature(sums, signature, publicKey: publicKey)) {
    return null;
  }
  return parseChecksums(sums)[file];
}

/// SHA-256 (hex) of [bytes], e.g. a file read in chunks.
Future<String> sha256Hex(Stream<List<int>> bytes) async {
  final sink = Sha256().newHashSink();
  await for (final chunk in bytes) {
    sink.add(chunk);
  }
  sink.close();
  return [
    for (final b in (await sink.hash()).bytes)
      b.toRadixString(16).padLeft(2, '0'),
  ].join();
}
