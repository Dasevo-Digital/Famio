import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('says what is still to set up, and notices progress', () async {
    final app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        // The reverse proxy answers for the public address.
        if (request.url.toString() == 'https://famio.example.org/api/health') {
          return http.Response('{"name":"famio","version":"x"}', 200);
        }
        return http.Response('nope', 502);
      }),
    );
    final admin = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      passwordHash: 'x',
      isAdmin: true,
    );
    final token = app.accounts.createSession(admin.id, method: 'password');
    Future<Map<String, SetupStep>> steps() async {
      final r = await app.handler(
        Request(
          'GET',
          Uri.parse('http://famio.test/api/admin/setup'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      expect(r.statusCode, 200);
      final json = jsonDecode(await r.readAsString()) as Map;
      return {
        for (final s in json['steps'] as List)
          (s as Map)['id'] as String: SetupStep.fromJson(s.cast()),
      };
    }

    final before = await steps();
    expect(
      before.keys,
      containsAll(['address', 'members', 'backup', 'region']),
    );
    for (final id in ['address', 'members', 'twoFactor', 'backup', 'region']) {
      expect(before[id]!.done, isFalse, reason: id);
      expect(before[id]!.where, isNotEmpty, reason: id);
    }

    app.settings.update({
      'publicUrl': 'https://famio.example.org',
      'holidayRegion': 'HE',
    });
    app.accounts.create(
      username: 'papa',
      displayName: 'Papa',
      passwordHash: 'x',
    );
    await app.backups!.run();
    final after = await steps();
    for (final id in ['address', 'members', 'backup', 'region']) {
      expect(after[id]!.done, isTrue, reason: '$id: ${after[id]!.detail}');
    }
    // Papa has no phone with notifications yet.
    expect(after['push']!.done, isFalse);
    expect(after['push']!.detail, contains('Papa'));

    // A public address the server cannot reach is named.
    app.settings.update({'publicUrl': 'https://kaputt.example.org/'});
    expect((await steps())['address']!.done, isFalse);
  });
}
