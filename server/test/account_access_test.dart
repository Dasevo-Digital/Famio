import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/dav/caldav_server.dart' show CalDavServer;
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// A session is not the password: what outlasts a session asks for it.
void main() {
  const password = 'tulpe-regal-7';
  late FamioServerApp app;
  late FamilyMember mama, papa, sso;
  late Map<String, String> tokens;

  setUp(() async {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
    sso = app.accounts.create(username: 'sso', displayName: 'Ohne Passwort');
    await app.accounts.setPassword(mama.id, password);
    await app.accounts.setPassword(papa.id, password);
    tokens = {
      for (final m in [mama, papa, sso]) m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<Response> call(
    FamilyMember who,
    String method,
    String path, [
    Object? body,
  ]) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/$path'),
      headers: {
        'authorization': 'Bearer ${tokens[who.id]}',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<String> appPassword(FamilyMember who) async {
    final made = await call(who, 'POST', 'api/me/app-passwords', {
      'name': 'Kalender',
      'password': password,
    });
    expect(made.statusCode, 201);
    return (jsonDecode(await made.readAsString()) as Map)['secret'] as String;
  }

  Future<int> davStatus(FamilyMember who, String secret) async {
    final auth =
        'Basic ${base64.encode(utf8.encode('${who.username}:$secret'))}';
    final r = await app.handler(
      Request(
        'PROPFIND',
        Uri.parse(
          'http://famio.test/dav/calendars/${who.username}/${CalDavServer.calendarSlug}/',
        ),
        headers: {'authorization': auth, 'depth': '0'},
      ),
    );
    return r.statusCode;
  }

  final needsPassword = <String, (String, Map<String, Object?>)>{
    'calendar password': ('api/me/app-passwords', {'name': 'Kalender'}),
    'apple profile': (
      'api/me/apple-profile',
      {'url': 'https://famio.example.org/'},
    ),
    'calendar feed': ('api/calendar/feeds', {'name': 'Plan', 'scope': 'all'}),
    'push address': (
      'api/me/push',
      {'name': 'Handy', 'url': 'https://ntfy.example.org/thema'},
    ),
    'two-factor setup': ('api/me/two-factor/totp', const {}),
  };

  group('what lasts asks for the password', () {
    for (final MapEntry(key: name, value: (path, body))
        in needsPassword.entries) {
      test('$name: without or with a wrong one no', () async {
        for (final extra in [
          const <String, Object?>{},
          const {'password': 'falsch-falsch-1'},
        ]) {
          final r = await call(mama, 'POST', path, {...body, ...extra});
          expect(r.statusCode, 403, reason: '$extra');
        }
      });
    }

    test('with the right one it works', () async {
      final made = await call(mama, 'POST', 'api/me/app-passwords', {
        'name': 'Kalender',
        'password': password,
      });
      expect(made.statusCode, 201);
      final totp = await call(mama, 'POST', 'api/me/two-factor/totp', {
        'password': password,
      });
      expect(totp.statusCode, 200);
    });

    test('an account without one has nothing to confirm', () async {
      final made = await call(sso, 'POST', 'api/me/app-passwords', {
        'name': 'Kalender',
      });
      expect(made.statusCode, 201);
    });
  });

  group('a new password', () {
    test('ends the calendar passwords of the old one', () async {
      final secret = await appPassword(papa);
      expect(await davStatus(papa, secret), 207);
      final changed = await call(papa, 'PUT', 'api/me/password', {
        'currentPassword': password,
        'newPassword': 'wiese-klang-9-neu',
      });
      expect(changed.statusCode, 200);
      expect(await davStatus(papa, secret), 401);
      expect(app.accounts.appPasswords(papa.id), isEmpty);
    });

    test('set by an admin ends them too', () async {
      final secret = await appPassword(papa);
      final reset = await call(
        mama,
        'PUT',
        'api/admin/users/${papa.id}/password',
        {'password': 'wiese-klang-9-neu'},
      );
      expect(reset.statusCode, 200);
      expect(await davStatus(papa, secret), 401);
    });
  });

  group('an admin on their own account', () {
    test('cannot set their password without the old one', () async {
      final r = await call(mama, 'PUT', 'api/admin/users/${mama.id}/password', {
        'password': 'wiese-klang-9-neu',
      });
      expect(r.statusCode, 403);
      expect((await app.accounts.verify('mama', 'wiese-klang-9-neu')), isNull);
    });

    test('needs the password to reset the second factor', () async {
      final without = await call(
        mama,
        'DELETE',
        'api/admin/users/${mama.id}/two-factor',
        const <String, Object?>{},
      );
      expect(without.statusCode, 403);
      final withIt = await call(
        mama,
        'DELETE',
        'api/admin/users/${mama.id}/two-factor',
        {'password': password},
      );
      expect(withIt.statusCode, 200);
    });

    test('still helps others without further proof', () async {
      final r = await call(
        mama,
        'DELETE',
        'api/admin/users/${papa.id}/two-factor',
      );
      expect(r.statusCode, 200);
    });
  });
}
