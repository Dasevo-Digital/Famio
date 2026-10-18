import 'dart:convert';

import 'package:famio_server/src/push/web_push_crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

void main() {
  group('RFC 8291', () {
    test('the example message encrypts to the published body', () {
      final body = encryptPush(
        utf8.encode('When I grow up, I want to be a watermelon'),
        uaPublic: unb64(
          'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
        ),
        authSecret: unb64('BTBZMqHH6r4Tts7J_aSIgg'),
        asPrivate: unb64('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'),
        salt: unb64('DGv6ra1nlYgDCS1FRnbzlw'),
      );
      expect(
        b64(body),
        'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
      );
    });

    test('a random key and salt every time', () {
      final ua = VapidKeys.generate();
      final auth = unb64('BTBZMqHH6r4Tts7J_aSIgg');
      final a = encryptPush(
        [1, 2, 3],
        uaPublic: ua.publicKey,
        authSecret: auth,
      );
      final b = encryptPush(
        [1, 2, 3],
        uaPublic: ua.publicKey,
        authSecret: auth,
      );
      expect(a.length, 16 + 4 + 1 + 65 + 3 + 1 + 16);
      expect(b64(a), isNot(b64(b)));
    });
  });

  group('VAPID', () {
    test('keys survive the settings round trip', () {
      final keys = VapidKeys.generate();
      expect(keys.privateKey, hasLength(32));
      expect(keys.publicKey, hasLength(65));
      expect(keys.publicKey.first, 4);
      final again = VapidKeys.fromJson(
        jsonDecode(jsonEncode(keys.toJson())) as Map<String, Object?>,
      );
      expect(again.privateKey, keys.privateKey);
      expect(again.publicKey, keys.publicKey);
    });

    test('the token is a valid ES256 JWT for the push origin', () {
      final keys = VapidKeys.generate();
      final now = DateTime.utc(2026, 10, 18, 12);
      final header = keys.authorization(
        Uri.parse('https://fcm.googleapis.com/fcm/send/abc'),
        subject: 'https://famio.example',
        now: now,
      );
      final match = RegExp(r'^vapid t=([^,]+), k=(.+)$').firstMatch(header)!;
      expect(match.group(2), b64(keys.publicKey));
      final parts = match.group(1)!.split('.');
      expect(parts, hasLength(3));
      expect(jsonDecode(utf8.decode(unb64(parts[0]))), {
        'typ': 'JWT',
        'alg': 'ES256',
      });
      final claims = jsonDecode(utf8.decode(unb64(parts[1])));
      expect(claims['aud'], 'https://fcm.googleapis.com');
      expect(claims['sub'], 'https://famio.example');
      expect(
        claims['exp'],
        now.add(const Duration(hours: 12)).millisecondsSinceEpoch ~/ 1000,
      );

      final sig = unb64(parts[2]);
      expect(sig, hasLength(64));
      final curve = ECDomainParameters('secp256r1');
      BigInt n(List<int> b) =>
          b.fold(BigInt.zero, (v, x) => (v << 8) | BigInt.from(x));
      final verifier = ECDSASigner(SHA256Digest())
        ..init(
          false,
          PublicKeyParameter<ECPublicKey>(
            ECPublicKey(curve.curve.decodePoint(keys.publicKey), curve),
          ),
        );
      expect(
        verifier.verifySignature(
          utf8.encode('${parts[0]}.${parts[1]}'),
          ECSignature(n(sig.sublist(0, 32)), n(sig.sublist(32))),
        ),
        isTrue,
      );
    });
  });
}
