import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/web_push_crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// What a browser does with a push message: decrypts it with its own key
/// (RFC 8291) and reads the JSON.
Map<String, Object?> _open(Uint8List body, VapidKeys browser, Uint8List auth) {
  final curve = ECDomainParameters('secp256r1');
  BigInt n(List<int> b) =>
      b.fold(BigInt.zero, (v, x) => (v << 8) | BigInt.from(x));
  Uint8List be32(BigInt v) {
    final out = Uint8List(32);
    for (var i = 31; i >= 0; i--, v >>= 8) {
      out[i] = (v & BigInt.from(0xff)).toInt();
    }
    return out;
  }

  Uint8List hkdf(List<int> ikm, List<int> salt, List<int> info, int length) {
    final out = Uint8List(length);
    (HKDFKeyDerivator(SHA256Digest())..init(
          HkdfParameters(
            Uint8List.fromList(ikm),
            length,
            Uint8List.fromList(salt),
            Uint8List.fromList(info),
          ),
        ))
        .deriveKey(null, 0, out, 0);
    return out;
  }

  final salt = body.sublist(0, 16);
  final idLength = body[20];
  final asPublic = body.sublist(21, 21 + idLength);
  final shared = be32(
    (ECDHBasicAgreement()..init(ECPrivateKey(n(browser.privateKey), curve)))
        .calculateAgreement(
          ECPublicKey(curve.curve.decodePoint(asPublic), curve),
        ),
  );
  final ikm = hkdf(shared, auth, [
    ...utf8.encode('WebPush: info'),
    0,
    ...browser.publicKey,
    ...asPublic,
  ], 32);
  final cek = hkdf(ikm, salt, [
    ...utf8.encode('Content-Encoding: aes128gcm'),
    0,
  ], 16);
  final nonce = hkdf(ikm, salt, [
    ...utf8.encode('Content-Encoding: nonce'),
    0,
  ], 12);
  final plain =
      (GCMBlockCipher(AESEngine())..init(
            false,
            AEADParameters(KeyParameter(cek), 128, nonce, Uint8List(0)),
          ))
          .process(body.sublist(21 + idLength));
  expect(plain.last, 2, reason: 'last-record delimiter');
  return (jsonDecode(utf8.decode(plain.sublist(0, plain.length - 1))) as Map)
      .cast();
}

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late String mamaToken;
  late String kindToken;
  late String mamaId;
  final sent = <http.Request>[];
  var status = 201;

  Future<Map<String, Object?>> call(
    String token,
    String method,
    String path, [
    Object? body,
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    return {
      '_status': response.statusCode,
      ...(jsonDecode(response.body) as Map).cast(),
    };
  }

  setUp(() async {
    sent.clear();
    status = 201;
    app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        sent.add(request);
        return http.Response('', status);
      }),
    );
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final setup =
        jsonDecode(
              (await http.post(
                base.resolve('api/auth/setup'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'username': 'mama',
                  'password': 'tulpe-regal-7',
                  'setupCode': app.setupCode,
                }),
              )).body,
            )
            as Map;
    mamaToken = setup['token'] as String;
    mamaId = (setup['member'] as Map)['id'] as String;
    await call(mamaToken, 'POST', 'api/admin/users', {
      'username': 'kind',
      'displayName': 'kind',
      'password': 'tulpe-regal-7',
      'role': MemberRole.child.name,
    });
    final login =
        jsonDecode(
              (await http.post(
                base.resolve('api/auth/login'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'username': 'kind',
                  'password': 'tulpe-regal-7',
                  'device': 'test',
                }),
              )).body,
            )
            as Map;
    kindToken = login['token'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  final browser = VapidKeys.generate();
  final auth = Uint8List.fromList(List.generate(16, (i) => i * 7));
  const endpoint = 'https://fcm.googleapis.com/fcm/send/abc123';

  Map<String, Object?> subscription([String url = endpoint]) => {
    'endpoint': url,
    'keys': {'p256dh': b64(browser.publicKey), 'auth': b64(auth)},
    'device': 'Firefox',
    'test': true,
  };

  test('the server key stays the same', () async {
    final a = await call(kindToken, 'GET', 'api/me/web-push');
    final b = await call(mamaToken, 'GET', 'api/me/web-push');
    expect(unb64(a['publicKey'] as String), hasLength(65));
    expect(a['publicKey'], b['publicKey']);
    expect(a['subscriptions'], isEmpty);
  });

  test('only push services of browsers, with valid keys', () async {
    for (final bad in [
      subscription('https://evil.example/push'),
      subscription('http://fcm.googleapis.com/fcm/send/x'),
      subscription('https://fcm.googleapis.com.evil.example/x'),
      {
        'endpoint': endpoint,
        'keys': {'p256dh': 'AAAA', 'auth': b64(auth)},
      },
      {'endpoint': endpoint},
    ]) {
      final r = await call(kindToken, 'POST', 'api/me/web-push', bad);
      expect(r['_status'], 400, reason: '$bad');
    }
    expect(sent, isEmpty);
  });

  test('a new browser gets an encrypted, signed test message', () async {
    final r = await call(
      kindToken,
      'POST',
      'api/me/web-push',
      subscription('https://web.push.apple.com/QGx'),
    );
    expect(r['_status'], 201);
    expect(r['lastError'], isNull);
    final push = sent.single;
    expect(push.url.toString(), 'https://web.push.apple.com/QGx');
    expect(push.headers['content-encoding'], 'aes128gcm');
    expect(push.headers['ttl'], '86400');
    final key = (await call(kindToken, 'GET', 'api/me/web-push'))['publicKey'];
    expect(push.headers['authorization'], endsWith(', k=$key'));
    final jwt = RegExp(r't=([^,]+)').firstMatch(push.headers['authorization']!);
    final claims = jsonDecode(utf8.decode(unb64(jwt!.group(1)!.split('.')[1])));
    expect(claims['aud'], 'https://web.push.apple.com');
    expect(_open(push.bodyBytes, browser, auth), {
      'title': 'Famio',
      'body': 'Benachrichtigungen funktionieren 🎉',
      'tag': 'tada',
    });
    final list = await call(kindToken, 'GET', 'api/me/web-push');
    final only = (list['subscriptions'] as List).single as Map;
    expect(only['device'], 'Firefox');
    expect(only['host'], 'web.push.apple.com');
  });

  test('chat messages reach the browser with details', () async {
    await call(kindToken, 'POST', 'api/me/web-push', subscription());
    sent.clear();
    await call(mamaToken, 'POST', 'api/sync', {
      'since': 0,
      'changes': [
        SyncRecord(
          collection: Collections.chatMessages,
          id: 'm1',
          data: {
            'chatId': ChatIds.family,
            'authorId': mamaId,
            'text': 'Essen ist fertig',
          },
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      ],
    });
    await app.push.idle;
    final message = _open(sent.single.bodyBytes, browser, auth);
    expect(message['body'], 'Essen ist fertig');
    expect(sent.single.headers['urgency'], 'normal');
  });

  test('renewing a subscription sends nothing and keeps one entry', () async {
    await call(kindToken, 'POST', 'api/me/web-push', subscription());
    sent.clear();
    final again = await call(kindToken, 'POST', 'api/me/web-push', {
      ...subscription(),
      'test': false,
    });
    expect(again['_status'], 201);
    expect(sent, isEmpty);
    expect(
      (await call(kindToken, 'GET', 'api/me/web-push'))['subscriptions'],
      hasLength(1),
    );
  });

  test('a subscription the push service forgot is removed', () async {
    await call(kindToken, 'POST', 'api/me/web-push', subscription());
    final id =
        (((await call(kindToken, 'GET', 'api/me/web-push'))['subscriptions']
                    as List)
                .single
            as Map)['id'];
    status = 410;
    final test = await call(kindToken, 'POST', 'api/me/web-push/$id/test');
    expect(test['ok'], isFalse);
    final list = await call(kindToken, 'GET', 'api/me/web-push');
    expect(list['subscriptions'], isEmpty);
  });

  test('only the own browsers can be removed', () async {
    await call(kindToken, 'POST', 'api/me/web-push', subscription());
    final id =
        (((await call(kindToken, 'GET', 'api/me/web-push'))['subscriptions']
                    as List)
                .single
            as Map)['id'];
    await call(mamaToken, 'DELETE', 'api/me/web-push/$id');
    await call(mamaToken, 'POST', 'api/me/web-push/unsubscribe', {
      'endpoint': endpoint,
    });
    expect(
      (await call(kindToken, 'GET', 'api/me/web-push'))['subscriptions'],
      hasLength(1),
    );
    await call(kindToken, 'POST', 'api/me/web-push/unsubscribe', {
      'endpoint': endpoint,
    });
    expect(
      (await call(kindToken, 'GET', 'api/me/web-push'))['subscriptions'],
      isEmpty,
    );
  });
}
