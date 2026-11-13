import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Who receives and changes health data: the server decides that itself,
/// not only `visibleTo`, which clients set and which may be empty.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, kid, oma, ha;
  late Map<String, String> tokens;
  var clock = 1000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
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
      for (final m in [mama, papa, kid, oma, ha])
        m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<SyncResponse> sync(
    FamilyMember who, {
    List<SyncRecord> changes = const [],
    int since = 0,
    String? scope,
  }) async {
    final response = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(
          SyncRequest(
            since: since,
            changes: changes,
            scope: scope,
            resettable: scope != null,
          ).toJson(),
        ),
      ),
    );
    expect(response.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await response.readAsString()) as Map).cast(),
    );
  }

  SyncRecord record(
    String collection,
    String id,
    Map<String, Object?> data, {
    List<String>? audience,
  }) => SyncRecord(
    collection: collection,
    id: id,
    data: {...data, SyncRecord.visibilityKey: ?audience},
    updatedAt: clock += 1000,
  );

  SyncRecord medication(String id, {List<String>? audience}) => record(
    Collections.medications,
    id,
    {'name': 'Sertralin', 'start': '2026-01-01', 'careIds': ?audience},
    audience: audience,
  );

  SyncRecord appointment(
    String id, {
    bool confidential = true,
    List<String> members = const [],
    StoredFile? file,
  }) => record(Collections.events, id, {
    if (file != null) 'files': [file.toJson()],
    'title': 'Psychotherapie',
    'location': 'Praxis',
    'notes': 'Thema',
    'start': '2026-12-01T10:00:00.000Z',
    'end': '2026-12-01T11:00:00.000Z',
    'confidential': confidential,
    'memberIds': members,
  });

  Future<Set<String>> sees(FamilyMember who) async => {
    for (final r in (await sync(who)).changes)
      if (!r.deleted) r.id,
  };

  group('receiving', () {
    test('health data nobody chose goes to adults only', () async {
      await sync(
        mama,
        changes: [
          medication('open'),
          record(Collections.documents, 'befund', {
            'title': 'Befund',
            'category': 'health',
          }),
          record(Collections.children, 'mia', {
            'name': 'Mia',
            'birthDate': '2020-01-01',
            'emergency': {'allergies': 'Nüsse'},
          }),
          record(Collections.documents, 'rechnung', {
            'title': 'Rechnung',
            'category': 'finance',
          }),
        ],
      );
      expect(await sees(papa), containsAll(['open', 'befund', 'mia']));
      expect(await sees(kid), {'rechnung'});
      expect(await sees(ha), {'rechnung'});
      expect(await sees(oma), isEmpty);
    });

    test('a named child receives it, a named service account never', () async {
      await sync(
        mama,
        changes: [
          medication('saft', audience: [mama.id, kid.id, ha.id]),
        ],
      );
      expect(await sees(kid), {'saft'});
      expect(await sees(ha), isEmpty);
    });

    test('old devices lose what they may no longer have', () async {
      await sync(mama, changes: [medication('open')]);
      // Their last sync was under the older rules.
      final next = await sync(ha, since: 1, scope: 'older');
      expect(next.reset, isTrue);
      expect(next.changes.where((r) => r.id == 'open'), isEmpty);
    });

    test('a health document cannot be fetched by a service account', () {
      const r = SyncRecord(
        collection: Collections.documents,
        id: 'befund',
        data: {'category': 'health'},
        updatedAt: 1,
      );
      expect(app.records.canAccess(r, mama.id), isTrue);
      expect(app.records.canAccess(r, ha.id), isFalse);
      expect(app.records.canAccess(r, kid.id), isFalse);
    });
  });

  group('a photo in the child log', () {
    Future<StoredFile> photo(FamilyMember owner) => app.files.save(
      owner: owner.id,
      name: 'ausschlag.jpg',
      mime: 'image/jpeg',
      body: Stream.value([1, 2, 3]),
    );
    SyncRecord log(String id, StoredFile file) =>
        record(Collections.childLogs, id, {
          'childId': 'mia',
          'kind': 'diaper',
          'diaper': 'dirty',
          'stoolColor': 'pale',
          'start': '2026-11-08T07:30:00.000Z',
          'photos': [file.toJson()],
        });

    test('goes only to those who receive the entry', () async {
      final file = await photo(mama);
      await sync(mama, changes: [log('windel', file)]);
      expect(app.files.mayRead(file, mama.id), isTrue);
      expect(app.files.mayRead(file, papa.id), isTrue);
      expect(app.files.mayRead(file, kid.id), isFalse);
      expect(app.files.mayRead(file, oma.id), isFalse);
      expect(app.files.mayRead(file, ha.id), isFalse);
      final stored = app.records.get(Collections.childLogs, 'windel')!;
      expect(stored.data['stoolColor'], 'pale');
      expect(app.records.referenced(file.id), isTrue);
    });

    test('someone else\'s file cannot be attached', () async {
      final file = await photo(papa);
      try {
        await sync(mama, changes: [log('fremd', file)]);
      } on Object {
        // The server refuses the whole request.
      }
      expect(app.records.get(Collections.childLogs, 'fremd'), isNull);
      expect(app.files.mayRead(file, mama.id), isFalse);
    });
  });

  group('changing', () {
    test('children leave plans alone, also where they are named', () async {
      final plan = medication('saft', audience: [mama.id, kid.id]);
      await sync(mama, changes: [plan]);
      final answer = await sync(
        kid,
        changes: [
          record(Collections.medications, 'saft', {
            'name': 'Saft',
            'dose': '10 Tabletten',
            'start': '2026-01-01',
          }),
        ],
      );
      expect(answer.rejected.map((r) => r.id), ['saft']);
      final stored = app.records.get(Collections.medications, 'saft')!;
      expect(stored.data['dose'], isNull);
      expect(stored.visibleTo, [mama.id, kid.id]);
    });

    test('a child who may log keeps the audience as it is', () async {
      final audience = [mama.id, kid.id];
      SyncRecord log(String id, {List<String>? to}) =>
          record(Collections.childLogs, id, {
            'childId': 'baby',
            'kind': 'feeding',
            'start': '2026-11-01T10:00:00.000Z',
          }, audience: to);
      expect(
        (await sync(kid, changes: [log('a', to: audience)])).rejected,
        [isA<SyncRecord>()].sublist(1),
      );
      expect(app.records.get(Collections.childLogs, 'a'), isNotNull);
      // Not for everyone.
      await sync(kid, changes: [log('a')]);
      expect(app.records.get(Collections.childLogs, 'a')!.visibleTo, audience);
      await sync(kid, changes: [log('b')]);
      expect(app.records.get(Collections.childLogs, 'b'), isNull);
    });

    test('a child ticks off what is on their plan', () async {
      await sync(
        mama,
        changes: [
          medication('saft', audience: [mama.id, kid.id]),
        ],
      );
      await sync(
        kid,
        changes: [
          record(
            Collections.medicationIntakes,
            'genommen',
            {
              'medicationId': 'saft',
              'at': '2026-11-01T10:00:00.000Z',
              'byId': kid.id,
            },
            audience: [mama.id, kid.id],
          ),
        ],
      );
      expect(
        app.records.get(Collections.medicationIntakes, 'genommen'),
        isNotNull,
      );
    });

    test('service accounts change no health data', () async {
      final answer = await sync(ha, changes: [medication('neu')]);
      expect(answer.rejected, isNotEmpty);
      expect(app.records.get(Collections.medications, 'neu'), isNull);
    });
  });

  group('deleting an account', () {
    test('takes their own health data, leaves the shared', () async {
      await sync(
        papa,
        changes: [
          record(Collections.memberEmergency, papa.id, {
            'info': {'allergies': 'Penicillin'},
          }),
          medication('allein', audience: [papa.id]),
          medication('gemeinsam', audience: [papa.id, mama.id]),
          record(
            Collections.documents,
            'befund',
            {'title': 'Befund', 'category': 'health'},
            audience: [papa.id],
          ),
          record(
            Collections.children,
            'mia',
            {'name': 'Mia', 'birthDate': '2020-01-01'},
            audience: [papa.id],
          ),
        ],
      );
      final before = app.records.currentRev;
      final response = await app.handler(
        Request(
          'DELETE',
          Uri.parse('http://famio.test/api/admin/users/${papa.id}'),
          headers: {'authorization': 'Bearer ${tokens[mama.id]}'},
        ),
      );
      expect(response.statusCode, 200);
      bool gone(String c, String id) => app.records.get(c, id)?.deleted ?? true;
      expect(gone(Collections.memberEmergency, papa.id), isTrue);
      expect(
        app.records.get(Collections.memberEmergency, papa.id)?.data.keys,
        isNot(contains('info')),
      );
      expect(gone(Collections.medications, 'allein'), isTrue);
      expect(gone(Collections.documents, 'befund'), isTrue);
      expect(gone(Collections.medications, 'gemeinsam'), isFalse);
      // A child's record is the family's, not one person's.
      expect(gone(Collections.children, 'mia'), isFalse);
      // Not in the bin either, and other devices hear of it.
      expect(app.records.trashFor(mama.id).$1, isEmpty);
      final seen = await sync(mama, since: before);
      expect(
        seen.changes.where((r) => r.deleted).map((r) => r.id),
        containsAll([papa.id]),
      );
    });
  });

  group('deleting an account also', () {
    test('takes what only they could see, with its files', () async {
      final file = await app.files.save(
        owner: papa.id,
        name: 'kontoauszug.pdf',
        mime: 'application/pdf',
        body: Stream.value(utf8.encode('%PDF privat')),
      );
      await sync(
        papa,
        changes: [
          record(
            Collections.notes,
            'tagebuch',
            {'title': 'Tagebuch', 'text': 'privat'},
            audience: [papa.id],
          ),
          record(
            Collections.documents,
            'auszug',
            {
              'title': 'Kontoauszug',
              'category': 'finance',
              'file': {
                'id': file.id,
                'name': 'kontoauszug.pdf',
                'mime': 'application/pdf',
                'size': file.size,
              },
            },
            audience: [papa.id],
          ),
          record(Collections.notes, 'familie', {
            'title': 'Einkaufsideen',
            'text': 'für alle',
          }),
          record(
            Collections.notes,
            'zu-zweit',
            {'title': 'Urlaub', 'text': 'zu zweit'},
            audience: [papa.id, mama.id],
          ),
        ],
      );
      expect(app.records.referenced(file.id), isTrue);
      final response = await app.handler(
        Request(
          'DELETE',
          Uri.parse('http://famio.test/api/admin/users/${papa.id}'),
          headers: {'authorization': 'Bearer ${tokens[mama.id]}'},
        ),
      );
      expect(response.statusCode, 200);
      bool gone(String c, String id) => app.records.get(c, id)?.deleted ?? true;
      expect(gone(Collections.notes, 'tagebuch'), isTrue);
      expect(gone(Collections.documents, 'auszug'), isTrue);
      expect(gone(Collections.notes, 'familie'), isFalse);
      expect(gone(Collections.notes, 'zu-zweit'), isFalse);
      // The upload is no longer referenced: the file maintenance removes it.
      expect(app.records.referenced(file.id), isFalse);
    });

    test(
      'takes the packing list of a private appointment, not timetables',
      () async {
        await sync(
          papa,
          changes: [
            record(
              Collections.events,
              'praxis',
              {
                'title': 'Praxis',
                'start': '2026-12-01T09:00:00.000Z',
                'end': '2026-12-01T10:00:00.000Z',
              },
              audience: [papa.id],
            ),
            record(Collections.shoppingLists, 'pack', {
              'name': '🧳 Praxis',
              'eventId': 'praxis',
            }),
            record(Collections.shoppingItems, 'karte', {
              'listId': 'pack',
              'name': 'Versichertenkarte',
            }),
            record(
              Collections.timetables,
              'mia',
              {'periods': const [], 'lessons': const []},
              audience: [papa.id],
            ),
          ],
        );
        final response = await app.handler(
          Request(
            'DELETE',
            Uri.parse('http://famio.test/api/admin/users/${papa.id}'),
            headers: {'authorization': 'Bearer ${tokens[mama.id]}'},
          ),
        );
        expect(response.statusCode, 200);
        bool gone(String c, String id) =>
            app.records.get(c, id)?.deleted ?? true;
        expect(gone(Collections.events, 'praxis'), isTrue);
        expect(gone(Collections.shoppingLists, 'pack'), isTrue);
        expect(gone(Collections.shoppingItems, 'karte'), isTrue);
        // A child's timetable stays, even if only this parent kept it.
        expect(gone(Collections.timetables, 'mia'), isFalse);
      },
    );

    test('works for a guest, who deletes their own account', () async {
      await app.accounts.setPassword(oma.id, 'tulpe-regal-7');
      final response = await app.handler(
        Request(
          'DELETE',
          Uri.parse('http://famio.test/api/me'),
          headers: {
            'authorization': 'Bearer ${tokens[oma.id]}',
            'content-type': 'application/json',
          },
          body: jsonEncode({'password': 'tulpe-regal-7'}),
        ),
      );
      expect(response.statusCode, 200, reason: await response.readAsString());
      expect(app.accounts.byId(oma.id), isNull);
    });
  });

  group('confidential appointments', () {
    test('reach whoever takes part, and adults', () async {
      await sync(
        mama,
        changes: [
          appointment('therapie'),
          appointment('kinderarzt', members: [kid.id]),
          appointment('turnen', confidential: false),
        ],
      );
      expect(await sees(papa), containsAll(['therapie', 'kinderarzt']));
      expect(await sees(kid), {'kinderarzt', 'turnen'});
      expect(await sees(oma), {'turnen'});
    });

    test('are only busy times for a service account', () async {
      await sync(mama, changes: [appointment('therapie')]);
      final event = (await sync(ha)).changes.single;
      expect(event.data['title'], '');
      expect(event.data['location'], '');
      expect(event.data['notes'], '');
      expect(event.data['confidential'], isTrue);
      expect(event.data['start'], isNotNull);
    });

    group('with a photo', () {
      Future<StoredFile> photo() => app.files.save(
        owner: mama.id,
        name: 'brief.jpg',
        mime: 'image/jpeg',
        body: Stream.value([1, 2, 3]),
      );

      test('it goes only to those who see the appointment', () async {
        final file = await photo();
        await sync(mama, changes: [appointment('therapie', file: file)]);
        expect(app.files.mayRead(file, papa.id), isTrue);
        expect(app.files.mayRead(file, kid.id), isFalse);
        expect(app.files.mayRead(file, oma.id), isFalse);
      });

      test('a service account gets neither the file nor its name', () async {
        final file = await photo();
        await sync(mama, changes: [appointment('therapie', file: file)]);
        expect(app.files.mayRead(file, ha.id), isFalse);
        final event = (await sync(ha)).changes.single;
        expect(event.data, isNot(contains('files')));
      });

      test('the trash keeps those rules', () async {
        final file = await photo();
        await sync(mama, changes: [appointment('therapie', file: file)]);
        final stored = app.records.get(Collections.events, 'therapie')!;
        await sync(
          mama,
          changes: [
            stored.copyWith(
              data: const {},
              updatedAt: stored.updatedAt + 1,
              deleted: true,
            ),
          ],
        );
        expect(app.files.mayRead(file, papa.id), isTrue);
        expect(app.files.mayRead(file, ha.id), isFalse);
      });

      test('an open appointment shares its photo with everyone', () async {
        final file = await photo();
        await sync(
          mama,
          changes: [appointment('turnen', confidential: false, file: file)],
        );
        expect(app.files.mayRead(file, kid.id), isTrue);
        expect(app.files.mayRead(file, ha.id), isTrue);
        final event = (await sync(ha)).changes.single;
        expect(event.data, contains('files'));
      });

      test('someone else\'s file cannot be attached', () async {
        final file = await app.files.save(
          owner: papa.id,
          name: 'privat.jpg',
          mime: 'image/jpeg',
          body: Stream.value([1, 2, 3]),
        );
        try {
          await sync(
            mama,
            changes: [appointment('fremd', confidential: false, file: file)],
          );
        } on Object {
          // The server refuses the whole request.
        }
        expect(app.records.get(Collections.events, 'fremd'), isNull);
        expect(app.files.mayRead(file, mama.id), isFalse);
      });
    });

    test('a service account leaves them alone', () async {
      await sync(mama, changes: [appointment('therapie')]);
      await sync(
        ha,
        changes: [
          record(Collections.events, 'therapie', {
            'title': '',
            'start': '2026-12-01T10:00:00.000Z',
            'end': '2026-12-01T11:00:00.000Z',
            'confidential': true,
          }),
        ],
      );
      expect(
        app.records.get(Collections.events, 'therapie')!.data['title'],
        'Psychotherapie',
      );
    });

    test('becoming confidential takes them and their comments away', () async {
      await sync(
        mama,
        changes: [
          appointment('therapie', confidential: false),
          record(Collections.eventComments, 'kommentar', {
            'eventId': 'therapie',
            'text': 'Bis dann',
            'memberId': mama.id,
            'at': '2026-11-01T10:00:00.000Z',
          }),
        ],
      );
      final rev = app.records.currentRev;
      expect(await sees(oma), {'therapie', 'kommentar'});
      await sync(mama, changes: [appointment('therapie')]);
      final next = await sync(oma, since: rev);
      expect(
        next.changes.where((r) => r.deleted).map((r) => r.id),
        containsAll(['therapie', 'kommentar']),
      );
      expect(await sees(oma), isEmpty);
    });
  });
}
