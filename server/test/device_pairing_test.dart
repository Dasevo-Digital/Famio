import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String session;

  Future<(int, Map)> call(
    String method,
    String path, {
    String? token,
    Object? body,
  }) async {
    final response = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/$path'),
        headers: {
          'authorization': ?(token == null ? null : 'Bearer $token'),
          'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await response.readAsString();
    return (
      response.statusCode,
      text.isEmpty ? <String, Object?>{} : jsonDecode(text) as Map,
    );
  }

  setUp(() async {
    app = FamioServerApp.inMemory();
    final (_, setup) = await call(
      'POST',
      'api/auth/setup',
      body: {
        'username': 'mama',
        'password': 'tulpe-regal-7',
        'setupCode': app.setupCode,
        'device': 'Erstes Gerät',
      },
    );
    session = setup['token'] as String;
  });

  tearDown(() => app.close());

  test('pairing signs the same account in exactly once', () async {
    final (created, pairing) = await call(
      'POST',
      'api/me/device-pairings',
      token: session,
    );
    expect(created, 201);
    final secret = pairing['secret'] as String;
    expect(secret.length, greaterThanOrEqualTo(32));
    expect(
      DateTime.parse(pairing['expiresAt'] as String).difference(DateTime.now()),
      lessThanOrEqualTo(const Duration(minutes: 5)),
    );

    final (paired, login) = await call(
      'POST',
      'api/auth/device-pair',
      body: {'secret': secret, 'device': 'Neues Gerät'},
    );
    expect(paired, 200);
    expect((login['member'] as Map)['username'], 'mama');
    expect(login['token'], isNot(session));
    final (_, twoFactor) = await call(
      'GET',
      'api/me/two-factor',
      token: login['token'] as String,
    );
    expect(twoFactor['sessionVerified'], isTrue);

    final (again, _) = await call(
      'POST',
      'api/auth/device-pair',
      body: {'secret': secret, 'device': 'Drittes Gerät'},
    );
    expect(again, 401, reason: 'the approval is consumed atomically');
  });

  test('only a signed-in device can create a pairing', () async {
    final (status, _) = await call('POST', 'api/me/device-pairings');
    expect(status, 401);
  });

  test('malformed public input is rejected without a server error', () async {
    final (status, error) = await call(
      'POST',
      'api/auth/device-pair',
      body: {'secret': 42, 'device': <String>[]},
    );
    expect(status, 401);
    expect(error['error'], 'invalid_pairing');
  });

  test('a new approval replaces the older one for the account', () async {
    final (_, first) = await call(
      'POST',
      'api/me/device-pairings',
      token: session,
    );
    final (_, second) = await call(
      'POST',
      'api/me/device-pairings',
      token: session,
    );
    expect(
      (await call(
        'POST',
        'api/auth/device-pair',
        body: {'secret': first['secret']},
      )).$1,
      401,
    );
    expect(
      (await call(
        'POST',
        'api/auth/device-pair',
        body: {'secret': second['secret']},
      )).$1,
      200,
    );
  });
}
