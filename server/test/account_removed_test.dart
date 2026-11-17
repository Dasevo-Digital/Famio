import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Devices of a removed account learn why they were signed out, so the app
/// keeps nothing of it (#560); any other ended session stays "unauthorized".
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<(int, String?)> syncWith(String token) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode(const SyncRequest(since: 0, changes: []).toJson()),
      ),
    );
    final body = (jsonDecode(await r.readAsString()) as Map).cast();
    return (r.statusCode, body['error'] as String?);
  }

  Future<int> removeByAdmin(String id, String adminToken) async {
    final r = await app.handler(
      Request(
        'DELETE',
        Uri.parse('http://famio.test/api/admin/users/$id'),
        headers: {'authorization': 'Bearer $adminToken'},
      ),
    );
    return r.statusCode;
  }

  test('an account removed by an admin', () async {
    final admin = app.accounts.createSession(mama.id);
    final phone = app.accounts.createSession(papa.id);
    final laptop = app.accounts.createSession(papa.id);
    expect((await syncWith(phone)).$1, 200);
    expect(await removeByAdmin(papa.id, admin), 200);
    for (final token in [phone, laptop]) {
      expect(await syncWith(token), (401, 'account_removed'));
    }
  });

  test('an account its owner deleted on another device', () async {
    final phone = app.accounts.createSession(papa.id);
    final laptop = app.accounts.createSession(papa.id);
    await app.accounts.setPassword(papa.id, 'Gartenzwerg-Laterne-91');
    final r = await app.handler(
      Request(
        'DELETE',
        Uri.parse('http://famio.test/api/me'),
        headers: {
          'authorization': 'Bearer $laptop',
          'content-type': 'application/json',
        },
        body: jsonEncode({'password': 'Gartenzwerg-Laterne-91'}),
      ),
    );
    expect(r.statusCode, 200);
    expect(await syncWith(phone), (401, 'account_removed'));
  });

  test('other ended sessions stay plain "unauthorized"', () async {
    final admin = app.accounts.createSession(mama.id);
    final signedOut = app.accounts.createSession(papa.id);
    final elsewhere = app.accounts.createSession(papa.id);
    app.accounts.deleteSession(signedOut);
    app.accounts.deleteSessions(papa.id);
    expect(await syncWith(signedOut), (401, 'unauthorized'));
    expect(await syncWith(elsewhere), (401, 'unauthorized'));
    expect(await syncWith('made-up-token'), (401, 'unauthorized'));
    expect((await syncWith(admin)).$1, 200);
  });

  test('the reasons go with the sessions\' idle time', () async {
    final admin = app.accounts.createSession(mama.id);
    final phone = app.accounts.createSession(papa.id);
    expect(await removeByAdmin(papa.id, admin), 200);
    expect(app.accounts.endedReason(phone), 'account_removed');
    app.db.execute('UPDATE ended_sessions SET at = 0');
    app.accounts.deleteExpiredSessions();
    expect(app.accounts.endedReason(phone), isNull);
    expect(await syncWith(phone), (401, 'unauthorized'));
  });
}
