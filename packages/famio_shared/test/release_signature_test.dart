import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  // Signed with the real release key by tool/sign_release.sh: proves that
  // the public key in the code belongs to it and that openssl's
  // signatures verify here.
  const sums = 'abc123  Famio-9.9.9-android.apk\n';
  const signature =
      '8ZmF+YREjMnx/baWvknJUU0+du/jgJSABQMG977NBUHkRxMS80rM1WSkP5h0qrykIY7iejSakDqAMx9dDR8hBg==';

  test('a signature of the release key verifies', () async {
    expect(await verifyReleaseSignature(sums, signature), isTrue);
    expect(await verifyReleaseSignature('$sums ', signature), isFalse);
    expect(
      await verifyReleaseSignature(
        sums.replaceFirst('9.9.9', '9.9.8'),
        signature,
      ),
      isFalse,
    );
    expect(await verifyReleaseSignature(sums, 'kein base64!'), isFalse);
    expect(await verifyReleaseSignature(sums, 'AAAA'), isFalse);
  });

  test('another key is not accepted', () async {
    final pair = await Ed25519().newKeyPair();
    final other = await Ed25519().sign(sums.codeUnits, keyPair: pair);
    final otherSig = base64Of(other.bytes);
    expect(await verifyReleaseSignature(sums, otherSig), isFalse);
    final pub = await pair.extractPublicKey();
    expect(
      await verifyReleaseSignature(
        sums,
        otherSig,
        publicKey: base64Of(pub.bytes),
      ),
      isTrue,
    );
  });

  test('checksums of a signed release', () async {
    final pair = await Ed25519().newKeyPair();
    final pub = base64Of((await pair.extractPublicKey()).bytes);
    final hash = 'a' * 64;
    final text =
        '$hash  Famio-2.1.0-android.apk\n${'b' * 64}  Famio-2.1.0-windows-x86_64.zip\n';
    final sig = base64Of(
      (await Ed25519().sign(text.codeUnits, keyPair: pair)).bytes,
    );
    expect(parseChecksums(text), hasLength(2));
    expect(
      await signedChecksum(
        text,
        sig,
        AppPlatform.android.fileName('2.1.0'),
        publicKey: pub,
      ),
      hash,
    );
    expect(
      await signedChecksum(text, sig, 'Famio-2.1.0-macOS.zip', publicKey: pub),
      isNull,
    );
    expect(
      await signedChecksum(text, sig, AppPlatform.android.fileName('2.1.0')),
      isNull,
      reason: 'not the release key',
    );
  });

  test('platform files and sha-256', () async {
    expect(
      AppPlatform.linux.fileName('2.0.0'),
      'Famio-2.0.0-linux-x86_64.tar.gz',
    );
    expect(AppPlatform.byName('windows'), AppPlatform.windows);
    expect(AppPlatform.byName('ios'), isNull);
    expect(
      await sha256Hex(Stream.fromIterable(['ab'.codeUnits, 'c'.codeUnits])),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}

String base64Of(List<int> bytes) => base64Encode(bytes);
