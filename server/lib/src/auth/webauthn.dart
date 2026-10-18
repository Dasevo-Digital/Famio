import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// The parts of WebAuthn (Level 2) a relying party needs for passkeys:
/// reading the authenticator's data and checking its signatures. No
/// attestation: Famio does not care which device holds the key.

/// Raised for anything that does not check out; the message stays generic
/// for the client.
class WebAuthnException implements Exception {
  const WebAuthnException(this.reason);

  final String reason;

  @override
  String toString() => 'WebAuthnException: $reason';
}

String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64url(String text) {
  try {
    return base64Url.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    throw const WebAuthnException('base64');
  }
}

/// What the authenticator signed (WebAuthn §6.1).
class AuthenticatorData {
  AuthenticatorData._(
    this.bytes,
    this.rpIdHash,
    this.flags,
    this.signCount,
    this.credentialId,
    this.publicKey,
  );

  factory AuthenticatorData.parse(Uint8List bytes) {
    if (bytes.length < 37) throw const WebAuthnException('authData');
    final flags = bytes[32];
    final count = ByteData.sublistView(bytes, 33, 37).getUint32(0);
    Uint8List? credentialId;
    Uint8List? publicKey;
    if (flags & 0x40 != 0) {
      // Attested credential data: AAGUID, id length, id, COSE key.
      if (bytes.length < 55) throw const WebAuthnException('authData');
      final length = ByteData.sublistView(bytes, 53, 55).getUint16(0);
      final keyStart = 55 + length;
      if (bytes.length <= keyStart) throw const WebAuthnException('authData');
      credentialId = bytes.sublist(55, keyStart);
      final reader = CborReader(bytes, keyStart)..read();
      publicKey = bytes.sublist(keyStart, reader.offset);
    }
    return AuthenticatorData._(
      bytes,
      bytes.sublist(0, 32),
      flags,
      count,
      credentialId,
      publicKey,
    );
  }

  final Uint8List bytes;
  final Uint8List rpIdHash;
  final int flags;
  final int signCount;

  /// Only when a credential was created.
  final Uint8List? credentialId;

  /// The COSE key (CBOR), only when a credential was created.
  final Uint8List? publicKey;

  bool get userPresent => flags & 0x01 != 0;
  bool get userVerified => flags & 0x04 != 0;

  /// [rpId]'s hash, user present and verified (fingerprint, face, PIN).
  void check(String rpId) {
    if (!_same(rpIdHash, crypto.sha256.convert(utf8.encode(rpId)).bytes)) {
      throw const WebAuthnException('rpId');
    }
    if (!userPresent || !userVerified) {
      throw const WebAuthnException('user verification');
    }
  }
}

/// The browser's part (WebAuthn §5.8.1): checks type, challenge and origin.
void checkClientData(
  Uint8List clientDataJson, {
  required String type,
  required String challenge,
  required String origin,
}) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(clientDataJson));
  } on FormatException {
    throw const WebAuthnException('clientData');
  }
  if (json is! Map ||
      json['type'] != type ||
      json['challenge'] != challenge ||
      json['origin'] != origin ||
      json['crossOrigin'] == true) {
    throw const WebAuthnException('clientData');
  }
}

/// The new credential in an `attestationObject` (format ignored: Famio
/// asks for "none").
AuthenticatorData readAttestation(Uint8List attestationObject) {
  final Object? decoded;
  decoded = CborReader(attestationObject).read();
  if (decoded is! Map || decoded['authData'] is! Uint8List) {
    throw const WebAuthnException('attestation');
  }
  final data = AuthenticatorData.parse(decoded['authData'] as Uint8List);
  if (data.credentialId == null || data.publicKey == null) {
    throw const WebAuthnException('attestation');
  }
  // Only keys Famio can check later.
  verifierFor(data.publicKey!);
  return data;
}

/// Checks [signature] over `authenticatorData || SHA-256(clientDataJSON)`
/// with the stored COSE [publicKey].
void checkSignature({
  required Uint8List publicKey,
  required Uint8List authenticatorData,
  required Uint8List clientDataJson,
  required Uint8List signature,
}) {
  final signed = Uint8List.fromList([
    ...authenticatorData,
    ...crypto.sha256.convert(clientDataJson).bytes,
  ]);
  if (!verifierFor(publicKey)(signed, signature)) {
    throw const WebAuthnException('signature');
  }
}

/// A check for the COSE key: ES256 (P-256) or RS256.
bool Function(Uint8List data, Uint8List signature) verifierFor(
  Uint8List coseKey,
) {
  final Object? key;
  key = CborReader(coseKey).read();
  if (key is! Map) throw const WebAuthnException('key');
  switch ((key[1], key[3])) {
    case (2, -7) when key[-1] == 1:
      final x = key[-2];
      final y = key[-3];
      if (x is! Uint8List || y is! Uint8List) {
        throw const WebAuthnException('key');
      }
      if (x.length != 32 || y.length != 32) {
        throw const WebAuthnException('key');
      }
      final curve = ECDomainParameters('secp256r1');
      final ECPoint point;
      try {
        point = curve.curve.decodePoint([4, ...x, ...y])!;
      } catch (_) {
        throw const WebAuthnException('key');
      }
      final public = ECPublicKey(point, curve);
      return (data, signature) {
        final (r, s) = _derSignature(signature);
        return (ECDSASigner(SHA256Digest())
              ..init(false, PublicKeyParameter<ECPublicKey>(public)))
            .verifySignature(data, ECSignature(r, s));
      };
    case (3, -257):
      final n = key[-1];
      final e = key[-2];
      if (n is! Uint8List || e is! Uint8List || n.length < 256) {
        throw const WebAuthnException('key');
      }
      final public = RSAPublicKey(_int(n), _int(e));
      return (data, signature) {
        try {
          return (RSASigner(SHA256Digest(), '0609608648016503040201')
                ..init(false, PublicKeyParameter<RSAPublicKey>(public)))
              .verifySignature(data, RSASignature(signature));
        } on ArgumentError {
          return false;
        }
      };
    default:
      throw const WebAuthnException('algorithm');
  }
}

/// `SEQUENCE { INTEGER r, INTEGER s }` (ASN.1 DER), as WebAuthn sends
/// ECDSA signatures.
(BigInt, BigInt) _derSignature(Uint8List der) {
  var i = 0;
  int byte() {
    if (i >= der.length) throw const WebAuthnException('signature');
    return der[i++];
  }

  int length() {
    final first = byte();
    if (first < 0x80) return first;
    if (first == 0x81) return byte();
    throw const WebAuthnException('signature');
  }

  BigInt integer() {
    if (byte() != 0x02) throw const WebAuthnException('signature');
    final n = length();
    if (n == 0 || n > 33 || i + n > der.length) {
      throw const WebAuthnException('signature');
    }
    final value = _int(der.sublist(i, i + n));
    i += n;
    return value;
  }

  if (byte() != 0x30) throw const WebAuthnException('signature');
  if (length() != der.length - i) throw const WebAuthnException('signature');
  final r = integer();
  final s = integer();
  if (i != der.length) throw const WebAuthnException('signature');
  return (r, s);
}

BigInt _int(List<int> bytes) =>
    bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// A small CBOR reader (RFC 8949) for what authenticators send: integers,
/// byte and text strings, arrays, maps and simple values. No indefinite
/// lengths, tags or floats (not used by WebAuthn).
class CborReader {
  CborReader(this._bytes, [this.offset = 0]);

  final Uint8List _bytes;
  int offset;
  var _depth = 0;

  Object? read() {
    if (++_depth > 16) throw const WebAuthnException('cbor depth');
    try {
      final head = _byte();
      final major = head >> 5;
      final info = head & 0x1f;
      if (major == 7) {
        return switch (info) {
          20 => false,
          21 => true,
          22 => null,
          _ => throw const WebAuthnException('cbor simple'),
        };
      }
      final n = _argument(info);
      switch (major) {
        case 0:
          return n;
        case 1:
          return -1 - n;
        case 2:
          return _take(n);
        case 3:
          try {
            return utf8.decode(_take(n));
          } on FormatException {
            throw const WebAuthnException('cbor text');
          }
        case 4:
          _fits(n);
          return [for (var k = 0; k < n; k++) read()];
        case 5:
          _fits(n);
          return {for (var k = 0; k < n; k++) read(): read()};
        default:
          throw const WebAuthnException('cbor tag');
      }
    } finally {
      _depth--;
    }
  }

  int _byte() {
    if (offset >= _bytes.length) throw const WebAuthnException('cbor end');
    return _bytes[offset++];
  }

  int _argument(int info) {
    if (info < 24) return info;
    final size = switch (info) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => throw const WebAuthnException('cbor length'),
    };
    var n = 0;
    for (var k = 0; k < size; k++) {
      n = (n << 8) | _byte();
    }
    // Beyond 2^53: nothing in WebAuthn, and not exact in JavaScript.
    if (n < 0 || n > 0x1fffffffffffff) {
      throw const WebAuthnException('cbor length');
    }
    return n;
  }

  /// [n] items need at least [n] more bytes.
  void _fits(int n) {
    if (n > _bytes.length - offset) throw const WebAuthnException('cbor end');
  }

  Uint8List _take(int n) {
    if (n > _bytes.length - offset) throw const WebAuthnException('cbor end');
    final out = _bytes.sublist(offset, offset + n);
    offset += n;
    return out;
  }
}
