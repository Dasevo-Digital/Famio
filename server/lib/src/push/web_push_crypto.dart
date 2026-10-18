import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The cryptography of Web Push: the server's VAPID key (RFC 8292) and the
/// end-to-end encryption of every message for the browser (RFC 8291,
/// aes128gcm). The push services of Google, Apple and Mozilla only ever
/// see ciphertext.

final _curve = ECDomainParameters('secp256r1');

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64(String text) =>
    base64Url.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));

/// The server's P-256 key pair for VAPID.
class VapidKeys {
  VapidKeys(this.privateKey, this.publicKey);

  /// A new random key pair.
  factory VapidKeys.generate() {
    final (d, q) = _newKeyPair();
    return VapidKeys(d, q);
  }

  factory VapidKeys.fromJson(Map<String, Object?> json) => VapidKeys(
    unb64(json['private'] as String),
    unb64(json['public'] as String),
  );

  /// The private scalar (32 bytes).
  final Uint8List privateKey;

  /// The uncompressed public point (65 bytes), the browsers'
  /// `applicationServerKey`.
  final Uint8List publicKey;

  Map<String, Object?> toJson() => {
    'private': b64(privateKey),
    'public': b64(publicKey),
  };

  /// `Authorization: vapid t=…, k=…` for a push to [endpoint]: a JWT
  /// (ES256) for the push service's origin, valid for 12 hours.
  String authorization(Uri endpoint, {required String subject, DateTime? now}) {
    final expiry =
        (now ?? DateTime.now())
            .add(const Duration(hours: 12))
            .millisecondsSinceEpoch ~/
        1000;
    final header = b64(utf8.encode(jsonEncode({'typ': 'JWT', 'alg': 'ES256'})));
    final claims = b64(
      utf8.encode(
        jsonEncode({
          'aud': '${endpoint.scheme}://${endpoint.authority}',
          'exp': expiry,
          'sub': subject,
        }),
      ),
    );
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(
        true,
        PrivateKeyParameter<ECPrivateKey>(
          ECPrivateKey(_int(privateKey), _curve),
        ),
      );
    final sig =
        signer.generateSignature(utf8.encode('$header.$claims')) as ECSignature;
    final jws = Uint8List.fromList([..._bytes(sig.r), ..._bytes(sig.s)]);
    return 'vapid t=$header.$claims.${b64(jws)}, k=${b64(publicKey)}';
  }
}

/// [payload] encrypted for one browser subscription ([uaPublic], the
/// `p256dh` key, and [authSecret], the `auth` value): the body of the push
/// request, `Content-Encoding: aes128gcm`. [asPrivate] and [salt] only for
/// the test vector of RFC 8291; normally both are new random values.
Uint8List encryptPush(
  List<int> payload, {
  required Uint8List uaPublic,
  required Uint8List authSecret,
  Uint8List? asPrivate,
  Uint8List? salt,
}) {
  final Uint8List asPriv;
  final Uint8List asPub;
  if (asPrivate == null) {
    (asPriv, asPub) = _newKeyPair();
  } else {
    asPriv = asPrivate;
    asPub = Uint8List.fromList((_curve.G * _int(asPrivate))!.getEncoded(false));
  }
  final ecdh = ECDHBasicAgreement()..init(ECPrivateKey(_int(asPriv), _curve));
  final shared = _bytes(
    ecdh.calculateAgreement(
      ECPublicKey(_curve.curve.decodePoint(uaPublic), _curve),
    ),
  );

  final ikm = _hkdf(shared, authSecret, [
    ...utf8.encode('WebPush: info'),
    0,
    ...uaPublic,
    ...asPub,
  ], 32);
  final saltBytes = salt ?? _random(16);
  final cek = _hkdf(ikm, saltBytes, [
    ...utf8.encode('Content-Encoding: aes128gcm'),
    0,
  ], 16);
  final nonce = _hkdf(ikm, saltBytes, [
    ...utf8.encode('Content-Encoding: nonce'),
    0,
  ], 12);
  // One record: the payload and the last-record delimiter 0x02.
  final gcm = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(cek), 128, nonce, Uint8List(0)));
  final sealed = gcm.process(Uint8List.fromList([...payload, 2]));
  const recordSize = 4096;
  return Uint8List.fromList([
    ...saltBytes,
    (recordSize >> 24) & 0xff,
    (recordSize >> 16) & 0xff,
    (recordSize >> 8) & 0xff,
    recordSize & 0xff,
    asPub.length,
    ...asPub,
    ...sealed,
  ]);
}

Uint8List _hkdf(List<int> ikm, List<int> salt, List<int> info, int length) {
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(
      HkdfParameters(
        Uint8List.fromList(ikm),
        length,
        Uint8List.fromList(salt),
        Uint8List.fromList(info),
      ),
    );
  final out = Uint8List(length);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

(Uint8List, Uint8List) _newKeyPair() {
  final generator = ECKeyGenerator()
    ..init(
      ParametersWithRandom(ECKeyGeneratorParameters(_curve), _secureRandom()),
    );
  final pair = generator.generateKeyPair();
  return (
    _bytes(pair.privateKey.d!),
    Uint8List.fromList(pair.publicKey.Q!.getEncoded(false)),
  );
}

SecureRandom _secureRandom() =>
    FortunaRandom()..seed(KeyParameter(_random(32)));

Uint8List _random(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

BigInt _int(List<int> bytes) =>
    bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));

/// [v] as 32 big-endian bytes.
Uint8List _bytes(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}
