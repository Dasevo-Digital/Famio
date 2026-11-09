import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/dav/caldav_server.dart' show CalDavServer;
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Every way out of the server follows the rules of the sync: calendar apps,
/// the trash, the export, conflict copies and comments.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, kid, oma, ha;
  late Map<String, String> tokens;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    kid = app.accounts.create(
      username: 'kid',
      displayName: 'Kid',
      role: MemberRole.child,
    );
    oma = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    ha = app.accounts.create(
      username: 'ha',
      displayName: 'HA',
      role: MemberRole.service,
    );
    tokens = {
      for (final m in [mama, kid, oma, ha])
        m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<Response> call(
    FamilyMember who,
    String method,
    String path, {
    Object? body,
  }) async => app.handler(
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

  Future<SyncResponse> sync(
    FamilyMember who, {
    List<SyncRecord> changes = const [],
    int since = 0,
  }) async {
    final r = await call(
      who,
      'POST',
      'api/sync',
      body: SyncRequest(since: since, changes: changes).toJson(),
    );
    expect(r.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    );
  }

  SyncRecord appointment(
    String id, {
    List<String> members = const [],
    Map<String, Object?> extra = const {},
    int? at,
  }) => SyncRecord(
    collection: Collections.events,
    id: id,
    data: {
      'title': 'Psychotherapie',
      'location': 'Praxis',
      'notes': 'Thema',
      'start': '2026-12-01T10:00:00.000Z',
      'end': '2026-12-01T11:00:00.000Z',
      'confidential': true,
      'memberIds': members,
      ...extra,
    },
    updatedAt: at ?? (clock += 1000),
  );

  SyncRecord deleted(String id) => SyncRecord(
    collection: Collections.events,
    id: id,
    data: const {},
    deleted: true,
    updatedAt: clock += 1000,
  );

  SyncRecord comment(String id, String eventId) => SyncRecord(
    collection: Collections.eventComments,
    id: id,
    data: {
      'eventId': eventId,
      'text': 'Befund liegt vor',
      'authorId': mama.id,
      'at': '2026-11-01T10:00:00.000Z',
    },
    updatedAt: clock += 1000,
  );

  Future<bool> hasComment(FamilyMember who, String id) async =>
      (await sync(who)).changes.any((r) => r.id == id && !r.deleted);

  Future<String> davAuth(FamilyMember who, {required bool confidential}) async {
    final made = await call(
      who,
      'POST',
      'api/me/app-passwords',
      body: {'name': 'Kalender', 'includeConfidential': confidential},
    );
    final secret =
        (jsonDecode(await made.readAsString()) as Map)['secret'] as String;
    return 'Basic ${base64.encode(utf8.encode('${who.username}:$secret'))}';
  }

  Future<Response> davGet(FamilyMember who, String auth, String path) async =>
      app.handler(
        Request(
          'GET',
          Uri.parse('http://famio.test/dav/calendars/${who.username}/$path'),
          headers: {'authorization': auth},
        ),
      );

  Future<String> davDelta(FamilyMember who, String auth, String slug) async {
    final r = await app.handler(
      Request(
        'REPORT',
        Uri.parse('http://famio.test/dav/calendars/${who.username}/$slug/'),
        headers: {'authorization': auth, 'depth': '1'},
        body:
            '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:">'
            '<d:sync-token>http://famio.app/ns/sync/1</d:sync-token>'
            '<d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop>'
            '</d:sync-collection>',
      ),
    );
    expect(r.statusCode, 207);
    return r.readAsString();
  }

  group('calendar apps', () {
    const events = CalDavServer.calendarSlug;
    const tasks = CalDavServer.tasksSlug;

    test('confidential appointments need a part in them', () async {
      await sync(
        mama,
        changes: [
          appointment('secret'),
          appointment('hers', members: [kid.id]),
        ],
      );
      final child = await davAuth(kid, confidential: true);
      expect((await davGet(kid, child, '$events/secret.ics')).statusCode, 404);
      expect(await davDelta(kid, child, events), isNot(contains('secret')));
      final own = await davGet(kid, child, '$events/hers.ics');
      expect(own.statusCode, 200);
      expect(await own.readAsString(), contains('SUMMARY:Psychotherapie'));

      final guest = await davAuth(oma, confidential: true);
      expect((await davGet(oma, guest, '$events/secret.ics')).statusCode, 404);

      final adult = await davAuth(mama, confidential: true);
      expect((await davGet(mama, adult, '$events/secret.ics')).statusCode, 200);
    });

    test('a guest gets only their own tasks', () async {
      await sync(
        mama,
        changes: [
          SyncRecord(
            collection: Collections.tasks,
            id: 'family',
            data: const {'title': 'Nur Familie'},
            updatedAt: clock += 1000,
          ),
          SyncRecord(
            collection: Collections.tasks,
            id: 'forher',
            data: {
              'title': 'Kuchen backen',
              'assigneeId': oma.id,
              'assigneeIds': [oma.id],
            },
            updatedAt: clock += 1000,
          ),
        ],
      );
      final guest = await davAuth(oma, confidential: false);
      expect((await davGet(oma, guest, '$tasks/family.ics')).statusCode, 404);
      expect((await davGet(oma, guest, '$tasks/forher.ics')).statusCode, 200);
      final delta = await davDelta(oma, guest, tasks);
      expect(delta, isNot(contains('Nur Familie')));
      expect(delta, contains('forher'));
      expect(
        RegExp(r'family\.ics.*?200 OK', dotAll: true).hasMatch(delta),
        isFalse,
      );
    });

    test('a service account never gets what is confidential', () async {
      await sync(mama, changes: [appointment('secret')]);
      final auth = await davAuth(ha, confidential: true);
      expect((await davGet(ha, auth, '$events/secret.ics')).statusCode, 404);
      final delta = await davDelta(ha, auth, events);
      expect(
        RegExp(r'secret\.ics.*?200 OK', dotAll: true).hasMatch(delta),
        isFalse,
      );
    });
  });

  group('service accounts', () {
    test('a refused write does not echo the confidential text', () async {
      app.accounts.update(ha.id, serviceAccess: ServiceAccess.readOnly);
      await sync(mama, changes: [appointment('e1')]);
      final answer = await sync(
        ha,
        changes: [
          SyncRecord(
            collection: Collections.events,
            id: 'e1',
            data: const {
              'title': 'x',
              'start': '2026-12-01T10:00:00.000Z',
              'end': '2026-12-01T11:00:00.000Z',
            },
            updatedAt: clock += 1000,
          ),
        ],
      );
      final echo = answer.rejected.singleWhere((r) => r.id == 'e1');
      expect(echo.data['title'], '');
      expect(echo.data['location'], '');
      expect(echo.data['notes'], '');
    });

    test('the trash shows no confidential appointment', () async {
      await sync(mama, changes: [appointment('e2')]);
      await sync(mama, changes: [deleted('e2')]);
      final seen = await call(ha, 'GET', 'api/trash');
      expect(seen.statusCode, 200);
      expect(await seen.readAsString(), isNot(contains('Psychotherapie')));
      final theirs = await call(mama, 'GET', 'api/trash');
      expect(await theirs.readAsString(), contains('Psychotherapie'));
    });

    test('the export holds only a busy time', () async {
      await sync(mama, changes: [appointment('e3')]);
      final r = await call(ha, 'POST', 'api/me/export', body: {'password': ''});
      expect(r.statusCode, 200);
      final zip = ZipDecoder().decodeBytes(
        await r.read().expand((c) => c).toList(),
      );
      final events = utf8.decode(
        zip.files.singleWhere((f) => f.name == 'records/events.json').content,
      );
      expect(events, isNot(contains('Psychotherapie')));
      expect(events, isNot(contains('Praxis')));
    });

    test('a conflict about a confidential appointment stays away', () async {
      final base = clock += 1000;
      await sync(
        ha,
        changes: [
          appointment(
            'k',
            extra: const {'title': 'Termin', 'confidential': false},
            at: base + 5000,
          ),
        ],
      );
      await sync(
        mama,
        changes: [
          appointment('k', extra: const {'notes': 'Diagnose'}, at: base + 1000),
        ],
      );
      List<SyncRecord> conflicts(SyncResponse r) => [
        for (final c in r.changes)
          if (c.collection == Collections.conflicts && !c.deleted) c,
      ];
      expect(conflicts(await sync(mama)), hasLength(1));
      expect(conflicts(await sync(ha)), isEmpty);
    });
  });

  group('comments', () {
    test('of a deleted confidential appointment reach only adults', () async {
      await sync(mama, changes: [appointment('e5')]);
      await sync(mama, changes: [comment('c5', 'e5')]);
      expect(await hasComment(kid, 'c5'), isFalse);
      await sync(mama, changes: [deleted('e5')]);
      for (final other in [kid, oma, ha]) {
        expect(await hasComment(other, 'c5'), isFalse, reason: other.username);
      }
      expect(await hasComment(mama, 'c5'), isTrue);
    });

    test('come back with their appointment from the trash', () async {
      await sync(
        mama,
        changes: [
          appointment('e6', members: [kid.id]),
        ],
      );
      await sync(mama, changes: [comment('c6', 'e6')]);
      expect(await hasComment(kid, 'c6'), isTrue);
      await sync(mama, changes: [deleted('e6')]);
      expect(await hasComment(kid, 'c6'), isFalse);

      final trash =
          jsonDecode(
                await (await call(mama, 'GET', 'api/trash')).readAsString(),
              )
              as Map;
      final id = (trash['items'] as List).single['id'];
      final restored = await call(mama, 'POST', 'api/trash/$id/restore');
      expect(restored.statusCode, 200);
      expect(await hasComment(kid, 'c6'), isTrue);
    });

    test('reach devices that dropped them when it comes back', () async {
      await sync(
        mama,
        changes: [
          appointment('e10', members: [kid.id]),
        ],
      );
      await sync(mama, changes: [comment('c10', 'e10')]);
      await sync(mama, changes: [deleted('e10')]);
      // A full sync while it is in the trash takes the comment off the device.
      final during = await sync(kid);
      expect(during.changes.any((r) => r.id == 'c10' && !r.deleted), isFalse);

      final trash =
          jsonDecode(
                await (await call(mama, 'GET', 'api/trash')).readAsString(),
              )
              as Map;
      final id = (trash['items'] as List).single['id'];
      expect(
        (await call(mama, 'POST', 'api/trash/$id/restore')).statusCode,
        200,
      );

      final after = await sync(kid, since: during.rev);
      expect(after.changes.any((r) => r.id == 'e10' && !r.deleted), isTrue);
      expect(after.changes.any((r) => r.id == 'c10' && !r.deleted), isTrue);
    });

    test('go for good once the trash has let go of the appointment', () async {
      await sync(
        mama,
        changes: [
          appointment('e7', extra: const {'confidential': false}),
        ],
      );
      await sync(mama, changes: [comment('c7', 'e7')]);
      await sync(mama, changes: [deleted('e7')]);

      expect(app.records.expireTrash(), 0);
      expect(await hasComment(mama, 'c7'), isTrue);

      expect(
        app.records.expireTrash(
          now: DateTime.now().add(const Duration(days: 31)),
        ),
        1,
      );
      expect(await hasComment(mama, 'c7'), isFalse);
    });

    test('of a connected calendar stay with everybody', () async {
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.externalEvents,
          id: 'x1',
          data: const {
            'title': 'Stadtfest',
            'start': '2026-12-01T10:00:00.000Z',
            'end': '2026-12-01T11:00:00.000Z',
          },
          updatedAt: clock += 1000,
        ),
      ]);
      await sync(mama, changes: [comment('c8', 'x1')]);
      expect(await hasComment(kid, 'c8'), isTrue);
    });

    test('of a live appointment are not affected', () async {
      await sync(
        mama,
        changes: [
          appointment('e9', extra: const {'confidential': false}),
        ],
      );
      await sync(mama, changes: [comment('c9', 'e9')]);
      expect(await hasComment(kid, 'c9'), isTrue);
      expect(await hasComment(ha, 'c9'), isTrue);
    });
  });
}
