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
    final papa = app.accounts.create(
      username: 'papa',
      displayName: 'Papa',
      passwordHash: 'x',
    );
    await app.backups!.run();
    final after = await steps();
    for (final id in ['address', 'members', 'backup', 'region']) {
      expect(after[id]!.done, isTrue, reason: '$id: ${after[id]!.detail}');
    }
    // Mama's app has no notifications yet; Papa has no app at all.
    expect(after['push']!.done, isFalse);
    expect(after['push']!.detail, contains('Noch nicht erreichbar: Mama.'));
    expect(after['push']!.detail, contains('Ohne Famio-App: Papa.'));
    // Papa on an iPhone: only ntfy reaches it until Apple's push service.
    app.accounts.createSession(papa.id, device: 'ios (Papas-iPhone)');
    final push = (await steps())['push']!;
    expect(push.detail, contains('Mama, Papa'));
    expect(push.detail, contains('Auf dem iPhone (Papa)'));
    expect(push.detail, isNot(contains('Ohne Famio-App')));
    // A child without any app is no gap to close.
    app.accounts.create(
      username: 'lena',
      displayName: 'Lena',
      passwordHash: 'x',
    );
    expect((await steps())['push']!.detail, contains('Ohne Famio-App: Lena.'));

    // A public address the server cannot reach is named, with the address
    // for the app to check it from the device.
    app.settings.update({'publicUrl': 'https://kaputt.example.org/'});
    final broken = (await steps())['address']!;
    expect(broken.done, isFalse);
    expect(broken.url, 'https://kaputt.example.org/');
  });
}
