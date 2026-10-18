import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/auth/webauthn.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// CBOR as an authenticator writes it (only what WebAuthn uses).
List<int> _cbor(Object? value) {
  List<int> head(int major, int n) {
    if (n < 24) return [major << 5 | n];
    if (n < 0x100) return [major << 5 | 24, n];
    if (n < 0x10000) return [major << 5 | 25, n >> 8, n & 0xff];
    return [major << 5 | 26, n >> 24, n >> 16 & 0xff, n >> 8 & 0xff, n & 0xff];
  }

  return switch (value) {
    final int n when n >= 0 => head(0, n),
    final int n => head(1, -1 - n),
    final Uint8List b => [...head(2, b.length), ...b],
    final String s => [...head(3, utf8.encode(s).length), ...utf8.encode(s)],
    final Map<Object?, Object?> m => [
      ...head(5, m.length),
      for (final e in m.entries) ...[..._cbor(e.key), ..._cbor(e.value)],
    ],
    _ => throw ArgumentError(value),
  };
}

Uint8List _be32(BigInt v) {
  final out = Uint8List(32);
  for (var i = 31; i >= 0; i--, v >>= 8) {
    out[i] = (v & BigInt.from(0xff)).toInt();
  }
  return out;
}

List<int> _derInt(BigInt v) {
  var bytes = _be32(v).toList();
  while (bytes.length > 1 && bytes.first == 0) {
    bytes = bytes.sublist(1);
  }
  if (bytes.first & 0x80 != 0) bytes = [0, ...bytes];
  return [2, bytes.length, ...bytes];
}

/// A phone with one passkey (P-256), as the browser hands it over.
class _Authenticator {
  _Authenticator() {
    final random = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(
            List.generate(32, (_) => Random.secure().nextInt(256)),
          ),
        ),
      );
    final pair =
        (ECKeyGenerator()..init(
              ParametersWithRandom(ECKeyGeneratorParameters(_curve), random),
            ))
            .generateKeyPair();
    _private = pair.privateKey;
    _public = pair.publicKey;
    _random = random;
  }

  static final _curve = ECDomainParameters('secp256r1');
  late final ECPrivateKey _private;
  late final ECPublicKey _public;
  late final SecureRandom _random;
  final credentialId = Uint8List.fromList(List.generate(16, (i) => i + 1));
  var counter = 0;
  var verified = true;
  String? userHandle;

  String get id => b64url(credentialId);

  Uint8List _authData(String rpId, {Uint8List? attested}) =>
      Uint8List.fromList([
        ...crypto.sha256.convert(utf8.encode(rpId)).bytes,
        0x01 | (verified ? 0x04 : 0) | (attested != null ? 0x40 : 0),
        counter >> 24 & 0xff,
        counter >> 16 & 0xff,
        counter >> 8 & 0xff,
        counter & 0xff,
        ...?attested,
      ]);

  Map<String, Object?> create(Map<String, Object?> options, String origin) {
    final rp = (options['rp'] as Map)['id'] as String;
    userHandle = (options['user'] as Map)['id'] as String;
    final cose = _cbor({
      1: 2,
      3: -7,
      -1: 1,
      -2: _be32(_public.Q!.x!.toBigInteger()!),
      -3: _be32(_public.Q!.y!.toBigInteger()!),
    });
    final attested = Uint8List.fromList([
      ...List.filled(16, 0),
      0,
      credentialId.length,
      ...credentialId,
      ...cose,
    ]);
    final clientData = utf8.encode(
      jsonEncode({
        'type': 'webauthn.create',
        'challenge': options['challenge'],
        'origin': origin,
        'crossOrigin': false,
      }),
    );
    return {
      'id': id,
      'rawId': id,
      'type': 'public-key',
      'response': {
        'clientDataJSON': b64url(clientData),
        'attestationObject': b64url(
          _cbor({
            'fmt': 'none',
            'attStmt': <Object?, Object?>{},
            'authData': _authData(rp, attested: attested),
          }),
        ),
      },
    };
  }

  Map<String, Object?> get(
    Map<String, Object?> options,
    String origin, {
    String? rpId,
  }) {
    final authData = _authData(rpId ?? options['rpId'] as String);
    final clientData = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'type': 'webauthn.get',
          'challenge': options['challenge'],
          'origin': origin,
        }),
      ),
    );
    final signer = ECDSASigner(SHA256Digest())
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(_private),
          _random,
        ),
      );
    final sig =
        signer.generateSignature(
              Uint8List.fromList([
                ...authData,
                ...crypto.sha256.convert(clientData).bytes,
              ]),
            )
            as ECSignature;
    final body = [..._derInt(sig.r), ..._derInt(sig.s)];
    return {
      'id': id,
      'rawId': id,
      'type': 'public-key',
      'response': {
        'clientDataJSON': b64url(clientData),
        'authenticatorData': b64url(authData),
        'signature': b64url([0x30, body.length, ...body]),
        'userHandle': userHandle,
      },
    };
  }
}

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late String token;
  late String origin;
  const password = 'tulpe-regal-7';

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Object? body,
    String? bearer,
    String? from,
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['content-type'] = 'application/json'
      ..headers['origin'] = from ?? origin;
    if (bearer != null) request.headers['authorization'] = 'Bearer $bearer';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    final decoded = jsonDecode(response.body);
    return {
      '_status': response.statusCode,
      if (decoded is Map) ...decoded.cast(),
    };
  }

  Future<void> addPasskey(_Authenticator phone) async {
    final options = await call(
      'POST',
      'api/me/passkeys/options',
      bearer: token,
      body: {'password': password},
    );
    expect(options['_status'], 200);
    final added = await call(
      'POST',
      'api/me/passkeys',
      bearer: token,
      body: {'name': 'Handy', 'credential': phone.create(options, origin)},
    );
    expect(added['_status'], 201, reason: '$added');
  }

  Future<Map<String, Object?>> signIn(
    _Authenticator phone, {
    String? rpId,
  }) async {
    final options = await call('POST', 'api/auth/passkey/options');
    return call(
      'POST',
      'api/auth/passkey',
      body: {
        'credential': phone.get(options, origin, rpId: rpId),
        'device': 'Laptop',
      },
    );
  }

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    origin = 'http://localhost:${server.port}';
    final setup = await call(
      'POST',
      'api/auth/setup',
      body: {
        'username': 'mama',
        'password': password,
        'setupCode': app.setupCode,
      },
    );
    token = setup['token'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  test('add a passkey, then sign in with it', () async {
    final phone = _Authenticator();
    await addPasskey(phone);
    final list = await call('GET', 'api/me/passkeys', bearer: token);
    final only = (list['passkeys'] as List).single as Map;
    expect(only['name'], 'Handy');
    expect(only['id'], phone.id);
    expect(only['lastUsed'], isNull);

    final login = await signIn(phone);
    expect(login['_status'], 200, reason: '$login');
    expect((login['member'] as Map)['username'], 'mama');
    final session = login['token'] as String;
    final status = await call('GET', 'api/me/two-factor', bearer: session);
    expect(status['sessionVerified'], isTrue);
    final again = await call('GET', 'api/me/passkeys', bearer: session);
    expect(((again['passkeys'] as List).single as Map)['lastUsed'], isNotNull);
  });

  test('a challenge works only once', () async {
    final phone = _Authenticator();
    await addPasskey(phone);
    final options = await call('POST', 'api/auth/passkey/options');
    final credential = phone.get(options, origin);
    final first = await call(
      'POST',
      'api/auth/passkey',
      body: {'credential': credential},
    );
    expect(first['_status'], 200);
    final replay = await call(
      'POST',
      'api/auth/passkey',
      body: {'credential': credential},
    );
    expect(replay['_status'], 401);
  });

  test('refused: wrong site, no fingerprint/PIN, forged signature', () async {
    final phone = _Authenticator();
    await addPasskey(phone);

    // Signed for another site.
    expect((await signIn(phone, rpId: 'evil.example'))['_status'], 401);

    // Only touched, not verified.
    phone.verified = false;
    expect((await signIn(phone))['_status'], 401);
    phone.verified = true;

    // Another key claiming the same id.
    final thief = _Authenticator()..userHandle = phone.userHandle;
    expect((await signIn(thief))['_status'], 401);

    // Answer from a page at another origin.
    final options = await call('POST', 'api/auth/passkey/options');
    final forged = await call(
      'POST',
      'api/auth/passkey',
      body: {'credential': phone.get(options, 'https://evil.example')},
    );
    expect(forged['_status'], 401);

    expect((await signIn(phone))['_status'], 200);
  });

  test('a counter that goes back means a copied key', () async {
    final phone = _Authenticator()..counter = 5;
    await addPasskey(phone);
    phone.counter = 6;
    expect((await signIn(phone))['_status'], 200);
    phone.counter = 6;
    expect((await signIn(phone))['_status'], 401);
  });

  test('adding needs the password and a page of this server', () async {
    final wrong = await call(
      'POST',
      'api/me/passkeys/options',
      bearer: token,
      body: {'password': 'falsch'},
    );
    expect(wrong['_status'], 403);
    expect(wrong['challenge'], isNull);
    final elsewhere = await call(
      'POST',
      'api/me/passkeys/options',
      bearer: token,
      from: 'https://evil.example',
      body: {'password': password},
    );
    expect(elsewhere['_status'], 400);
    final plainHttp = await call(
      'POST',
      'api/auth/passkey/options',
      from: 'http://famio.example',
    );
    expect(plainHttp['_status'], 400);
    // A challenge for the login does not register a key.
    final login = await call('POST', 'api/auth/passkey/options');
    final sneaky = await call(
      'POST',
      'api/me/passkeys',
      bearer: token,
      body: {
        'credential': _Authenticator().create({
          ...login,
          'rp': {'id': 'localhost'},
          'user': {'id': 'eA'},
        }, origin),
      },
    );
    expect(sneaky['_status'], 400);
    expect(
      (await call('GET', 'api/me/passkeys', bearer: token))['passkeys'],
      isEmpty,
    );
  });

  test('removed passkeys no longer sign in', () async {
    final phone = _Authenticator();
    await addPasskey(phone);
    await call('DELETE', 'api/me/passkeys/${phone.id}', bearer: token);
    expect((await signIn(phone))['_status'], 401);
  });

  test('RSA keys (RS256, e.g. Windows Hello) are checked too', () {
    final random = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i))));
    final pair =
        (RSAKeyGenerator()..init(
              ParametersWithRandom(
                RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
                random,
              ),
            ))
            .generateKeyPair();
    Uint8List bytes(BigInt v) {
      final hex = v.toRadixString(16);
      final even = hex.length.isOdd ? '0$hex' : hex;
      return Uint8List.fromList([
        for (var i = 0; i < even.length; i += 2)
          int.parse(even.substring(i, i + 2), radix: 16),
      ]);
    }

    final cose = Uint8List.fromList(
      _cbor({
        1: 3,
        3: -257,
        -1: bytes(pair.publicKey.modulus!),
        -2: bytes(pair.publicKey.exponent!),
      }),
    );
    final authData = Uint8List.fromList(List.filled(37, 5));
    final clientData = Uint8List.fromList(utf8.encode('{"type":"x"}'));
    final signed = Uint8List.fromList([
      ...authData,
      ...crypto.sha256.convert(clientData).bytes,
    ]);
    final signature =
        (RSASigner(SHA256Digest(), '0609608648016503040201')
              ..init(true, PrivateKeyParameter<RSAPrivateKey>(pair.privateKey)))
            .generateSignature(signed)
            .bytes;
    checkSignature(
      publicKey: cose,
      authenticatorData: authData,
      clientDataJson: clientData,
      signature: signature,
    );
    expect(
      () => checkSignature(
        publicKey: cose,
        authenticatorData: authData,
        clientDataJson: Uint8List.fromList(utf8.encode('{"type":"y"}')),
        signature: signature,
      ),
      throwsA(isA<WebAuthnException>()),
    );
  });

  // Answers of real browsers and authenticators, from the test suite of
  // py_webauthn (BSD-3-Clause, github.com/duo-labs/py_webauthn).
  group('real browser output', () {
    test('a registration ("none") yields id, key and counter', () {
      const id =
          '9y1xA8Tmg1FEmT-c7_fvWZ_uoTuoih3OvR45_oAK-cwHWhAbXrl2q62iLVTjiyEZ7O7n-CROOY494k7Q3xrs_w';
      final data = readAttestation(
        unb64url(
          'o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YVjESZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2NFAAAAFwAAAAAAAAAAAAAAAAAAAAAAQPctcQPE5oNRRJk_nO_371mf7qE7qIodzr0eOf6ACvnMB1oQG165dqutoi1U44shGezu5_gkTjmOPeJO0N8a7P-lAQIDJiABIVggSFbUJF-42Ug3pdM8rDRFu_N5oiVEysPDB6n66r_7dZAiWCDUVnB39FlGypL-qAoIO9xWHtJygo2jfDmHl-_eKFRLDA',
        ),
      )..check('localhost');
      expect(b64url(data.credentialId!), id);
      expect(
        b64url(data.publicKey!),
        'pQECAyYgASFYIEhW1CRfuNlIN6XTPKw0RbvzeaIlRMrDwwep-uq_-3WQIlgg1FZwd_RZRsqS_qgKCDvcVh7ScoKNo3w5h5fv3ihUSww',
      );
      expect(data.signCount, 23);
      checkClientData(
        unb64url(
          'eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiVHdON240V1R5R0tMYzRaWS1xR3NGcUtuSE00bmdscXN5VjBJQ0psTjJUTzlYaVJ5RnRya2FEd1V2c3FsLWdrTEpYUDZmbkYxTWxyWjUzTW00UjdDdnciLCJvcmlnaW4iOiJodHRwOi8vbG9jYWxob3N0OjUwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9',
        ),
        type: 'webauthn.create',
        challenge:
            'TwN7n4WTyGKLc4ZY-qGsFqKnHM4nglqsyV0ICJlN2TO9XiRyFtrkaDwUvsql-gkLJXP6fnF1MlrZ53Mm4R7Cvw',
        origin: 'http://localhost:5000',
      );
      expect(
        () => data.check('example.com'),
        throwsA(isA<WebAuthnException>()),
      );
    });

    test('a P-256 sign-in signature checks out', () {
      final authData = unb64url(
        'SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MBAAAATg',
      );
      final parsed = AuthenticatorData.parse(authData);
      expect(parsed.signCount, 78);
      // Only touched: Famio would refuse it (fingerprint/PIN required).
      expect(parsed.userVerified, isFalse);
      expect(
        () => parsed.check('localhost'),
        throwsA(isA<WebAuthnException>()),
      );
      final key = unb64url(
        'pQECAyYgASFYIIeDTe-gN8A-zQclHoRnGFWN8ehM1b7yAsa8I8KIvmplIlgg4nFGT5px8o6gpPZZhO01wdy9crDSA_Ngtkx0vGpvPHI',
      );
      final clientData = unb64url(
        'eyJjaGFsbGVuZ2UiOiJ4aTMwR1BHQUZZUnhWRHBZMXNNMTBEYUx6VlFHNjZudi1fN1JVYXpIMHZJMll2RzhMWWdERW52TjVmWlpOVnV2RUR1TWk5dGUzVkxxYjQyTjBma0xHQSIsImNsaWVudEV4dGVuc2lvbnMiOnt9LCJoYXNoQWxnb3JpdGhtIjoiU0hBLTI1NiIsIm9yaWdpbiI6Imh0dHA6Ly9sb2NhbGhvc3Q6NTAwMCIsInR5cGUiOiJ3ZWJhdXRobi5nZXQifQ',
      );
      final signature = unb64url(
        'MEUCIGisVZOBapCWbnJJvjelIzwpixxIwkjCCb5aCHafQu68AiEA88v-2pJNNApPFwAKFiNuf82-2hBxYW5kGwVweeoxCwo',
      );
      checkSignature(
        publicKey: key,
        authenticatorData: authData,
        clientDataJson: clientData,
        signature: signature,
      );
      final other = Uint8List.fromList(authData)..[36] ^= 1;
      expect(
        () => checkSignature(
          publicKey: key,
          authenticatorData: other,
          clientDataJson: clientData,
          signature: signature,
        ),
        throwsA(isA<WebAuthnException>()),
      );
    });

    test('an RSA sign-in (Windows Hello) checks out', () {
      final authData = unb64url(
        'SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MFAAAAAQ',
      );
      AuthenticatorData.parse(authData).check('localhost');
      final clientData = unb64url(
        'eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoiaVBtQWkxUHAxWEw2b0FncTNQV1p0WlBuWmExekZVRG9HYmFRMF9LdlZHMWxGMnMzUnRfM280dVN6Y2N5MHRtY1RJcFRUVDRCVTFULUk0bWFhdm5kalEiLCJvcmlnaW4iOiJodHRwOi8vbG9jYWxob3N0OjUwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9',
      );
      checkClientData(
        clientData,
        type: 'webauthn.get',
        challenge:
            'iPmAi1Pp1XL6oAgq3PWZtZPnZa1zFUDoGbaQ0_KvVG1lF2s3Rt_3o4uSzccy0tmcTIpTTT4BU1T-I4maavndjQ',
        origin: 'http://localhost:5000',
      );
      checkSignature(
        publicKey: unb64url(
          'pAEDAzkBACBZAQDfV20epzvQP-HtcdDpX-cGzdOxy73WQEvsU7Dnr9UWJophEfpngouvgnRLXaEUn_d8HGkp_HIx8rrpkx4BVs6X_B6ZjhLlezjIdJbLbVeb92BaEsmNn1HW2N9Xj2QM8cH-yx28_vCjf82ahQ9gyAr552Bn96G22n8jqFRQKdVpO-f-bvpvaP3IQ9F5LCX7CUaxptgbog1SFO6FI6ob5SlVVB00lVXsaYg8cIDZxCkkENkGiFPgwEaZ7995SCbiyCpUJbMqToLMgojPkAhWeyktu7TlK6UBWdJMHc3FPAIs0lH_2_2hKS-mGI1uZAFVAfW1X-mzKL0czUm2P1UlUox7IUMBAAE',
        ),
        authenticatorData: authData,
        clientDataJson: clientData,
        signature: unb64url(
          'iOHKX3erU5_OYP_r_9HLZ-CexCE4bQRrxM8WmuoKTDdhAnZSeTP0sjECjvjfeS8MJzN1ArmvV0H0C3yy_FdRFfcpUPZzdZ7bBcmPh1XPdxRwY747OrIzcTLTFQUPdn1U-izCZtP_78VGw9pCpdMsv4CUzZdJbEcRtQuRS03qUjqDaovoJhOqEBmxJn9Wu8tBi_Qx7A33RbYjlfyLm_EDqimzDZhyietyop6XUcpKarKqVH0M6mMrM5zTjp8xf3W7odFCadXEJg-ERZqFM0-9Uup6kJNLbr6C5J4NDYmSm3HCSA6lp2iEiMPKU8Ii7QZ61kybXLxsX4w4Dm3fOLjmDw',
        ),
      );
    });
  });

  group('CBOR', () {
    test('reads what authenticators write', () {
      final bytes = Uint8List.fromList(
        _cbor({
          'fmt': 'none',
          1: -257,
          -2: Uint8List.fromList([1, 2, 3]),
          'n': 70000,
        }),
      );
      expect(CborReader(bytes).read(), {
        'fmt': 'none',
        1: -257,
        -2: [1, 2, 3],
        'n': 70000,
      });
    });

    test('rejects truncated and absurd input', () {
      for (final bad in [
        [0xa1, 0x61],
        [0x5a, 0xff, 0xff, 0xff, 0xff],
        [0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        [0xc1, 0x00],
        List.filled(40, 0x81),
      ]) {
        expect(
          () => CborReader(Uint8List.fromList(bad)).read(),
          throwsA(isA<WebAuthnException>()),
          reason: '$bad',
        );
      }
    });
  });
}
