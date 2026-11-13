import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Children do not decide who sees something: what exists keeps its
/// audience when they change it, only their own private things they share.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, kid, guest;
  late Map<String, String> tokens;

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
    guest = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    tokens = {
      for (final m in [mama, papa, kid, guest])
        m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> call(
    FamilyMember who,
    String method,
    String path, [
    Object? body,
  ]) async {
    final response = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/$path'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return {
      '_status': response.statusCode,
      ...(jsonDecode(await response.readAsString()) as Map).cast(),
    };
  }

  Future<SyncResponse> sync(
    FamilyMember who, {
    List<SyncRecord> changes = const [],
    int since = 0,
  }) async {
    final response = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(SyncRequest(since: since, changes: changes).toJson()),
      ),
    );
    return SyncResponse.fromJson(
      (jsonDecode(await response.readAsString()) as Map).cast(),
    );
  }

  SyncRecord document(
    String id,
    String title, {
    List<String>? visibleTo,
    required int updatedAt,
    int rev = 0,
  }) => SyncRecord(
    collection: Collections.documents,
    id: id,
    data: {
      'title': title,
      'category': 'identity',
      SyncRecord.visibilityKey: ?visibleTo,
    },
    updatedAt: updatedAt,
    rev: rev,
  );

  test('a child cannot hide a family record from the parents', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(mama, changes: [document('pass', 'Reisepass', updatedAt: now)]);
    final rev = (await sync(papa)).rev;
    final stored = app.records.get(Collections.documents, 'pass')!;
    await sync(
      kid,
      changes: [
        document(
          'pass',
          'Reisepass (neu)',
          visibleTo: [kid.id],
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    final after = app.records.get(Collections.documents, 'pass')!;
    // The edit itself counts, the audience stays the family's.
    expect(after.data['title'], 'Reisepass (neu)');
    expect(after.visibleTo, isNull);
    final papaSees = (await sync(papa, since: rev)).changes.single;
    expect(papaSees.deleted, isFalse);
    expect(papaSees.data['title'], 'Reisepass (neu)');
  });

  test('a narrowed audience among adults stays as it was', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(
      mama,
      changes: [
        document(
          'zeugnis',
          'Zeugnis',
          visibleTo: [mama.id, papa.id, kid.id],
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.documents, 'zeugnis')!;
    await sync(
      kid,
      changes: [
        document(
          'zeugnis',
          'Zeugnis',
          visibleTo: [kid.id, papa.id],
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    expect(app.records.get(Collections.documents, 'zeugnis')!.visibleTo, [
      mama.id,
      papa.id,
      kid.id,
    ]);
  });

  test('what only the child sees, the child may share', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(
      kid,
      changes: [
        document('tagebuch', 'Notiz', visibleTo: [kid.id], updatedAt: now),
      ],
    );
    final stored = app.records.get(Collections.documents, 'tagebuch')!;
    await sync(
      kid,
      changes: [
        document(
          'tagebuch',
          'Notiz',
          visibleTo: [kid.id, mama.id],
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    expect(app.records.get(Collections.documents, 'tagebuch')!.visibleTo, [
      kid.id,
      mama.id,
    ]);
    expect((await sync(mama)).changes.any((r) => r.id == 'tagebuch'), isTrue);
  });

  test('a child cannot hide a family note through the bin', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(
      mama,
      changes: [
        SyncRecord(
          collection: Collections.notes,
          id: 'n1',
          data: {'title': 'Familienregeln', 'text': 'x'},
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.notes, 'n1')!;
    // Deleted with a local copy that only the child would see.
    await sync(
      kid,
      changes: [
        SyncRecord(
          collection: Collections.notes,
          id: 'n1',
          deleted: true,
          data: {
            'deletionSnapshot': {
              'title': 'Familienregeln',
              'text': 'x',
              SyncRecord.visibilityKey: [kid.id],
            },
          },
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    final bin = await call(mama, 'GET', 'api/trash');
    final items = (bin['items'] as List).cast<Map>();
    expect(items.map((i) => (i['record'] as Map)['id']), ['n1']);
    final restored = await call(
      kid,
      'POST',
      'api/trash/${items.single['id']}/restore',
      {},
    );
    expect(restored['_status'], 200);
    final after = app.records.get(Collections.notes, 'n1')!;
    expect(after.deleted, isFalse);
    expect(after.visibleTo, isNull);
  });

  test('a child cannot make a confidential appointment public', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = DateTime.now().add(const Duration(days: 1));
    final event = {
      'title': 'Psychotherapie',
      'start': start.toUtc().toIso8601String(),
      'end': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
      'confidential': true,
      'memberIds': [kid.id, mama.id],
    };
    await sync(
      mama,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: 'e1',
          data: event,
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.events, 'e1')!;
    await sync(
      kid,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: 'e1',
          data: {
            ...event,
            'confidential': false,
            'memberIds': [kid.id, mama.id, guest.id],
          },
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    final after = app.records.get(Collections.events, 'e1')!;
    expect(after.data['confidential'], isTrue);
    expect(after.data['memberIds'], [kid.id, mama.id]);
    expect((await sync(guest)).changes.where((r) => r.id == 'e1'), isEmpty);
  });

  test('a child cannot hide a family appointment either', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = DateTime.now().add(const Duration(days: 1));
    final event = {
      'title': 'Oma holt die Kinder ab',
      'start': start.toUtc().toIso8601String(),
      'end': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
      'memberIds': [kid.id],
    };
    await sync(
      mama,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: 'e2',
          data: event,
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.events, 'e2')!;
    await sync(
      kid,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: 'e2',
          data: {...event, 'confidential': true, 'memberIds': <String>[]},
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    final after = app.records.get(Collections.events, 'e2')!;
    expect(after.data['confidential'], isNot(true));
    expect(
      (await sync(guest)).changes.where((r) => r.id == 'e2' && !r.deleted),
      isNotEmpty,
    );
  });

  test('a child marks an own appointment private', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = DateTime.now().add(const Duration(days: 1));
    final event = {
      'title': 'Frauenarzt',
      'start': start.toUtc().toIso8601String(),
      'end': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
      'memberIds': [kid.id],
    };
    await sync(
      kid,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: 'e3',
          data: event,
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.events, 'e3')!;
    await sync(
      kid,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: 'e3',
          data: {...event, 'confidential': true},
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    expect(
      app.records.get(Collections.events, 'e3')!.data['confidential'],
      isTrue,
    );
    expect(
      (await sync(guest)).changes.where((r) => r.id == 'e3' && !r.deleted),
      isEmpty,
    );
  });

  test('the household book settings are for adults (#476)', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SyncRecord settings(List<String> members, int at, {List<String>? only}) =>
        SyncRecord(
          collection: Collections.budgetSettings,
          id: 'budget',
          data: {
            'memberIds': members,
            'limits': <String, Object?>{},
            SyncRecord.visibilityKey: ?only,
          },
          updatedAt: at,
          rev: app.records.get(Collections.budgetSettings, 'budget')?.rev ?? 0,
        );
    // First: a child cannot take them for itself.
    await sync(
      kid,
      changes: [
        settings([kid.id], now, only: [kid.id]),
      ],
    );
    expect(app.records.get(Collections.budgetSettings, 'budget'), isNull);
    await sync(
      mama,
      changes: [
        settings([mama.id, papa.id], now + 1000),
      ],
    );
    // Later: nor change whom they are for.
    await sync(
      kid,
      changes: [
        settings([kid.id], now + 2000),
      ],
    );
    final stored = app.records.get(Collections.budgetSettings, 'budget')!;
    expect(stored.data['memberIds'], [mama.id, papa.id]);
    expect(stored.updatedBy, mama.id);
  });

  group('whose appointment it is (#416)', () {
    Map<String, Object?> appointment(String title, List<String> members) {
      final start = DateTime.now().add(const Duration(days: 1));
      return {
        'title': title,
        'start': start.toUtc().toIso8601String(),
        'end': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
        'memberIds': members,
      };
    }

    Future<void> write(
      FamilyMember who,
      String id,
      Map<String, Object?> data,
      int updatedAt,
    ) => sync(
      who,
      changes: [
        SyncRecord(
          collection: Collections.events,
          id: id,
          data: data,
          updatedAt: updatedAt,
          rev: app.records.get(Collections.events, id)?.rev ?? 0,
        ),
      ],
    );

    Future<bool> guestSeesTitle(String id) async => (await sync(
      guest,
    )).changes.any((r) => r.id == id && !r.deleted && r.data['title'] != null);

    test('the server notes who entered it, whatever an app sends', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await write(kid, 'own', {
        ...appointment('Training', [kid.id]),
        CalendarEvent.createdByKey: mama.id,
      }, now);
      expect(
        app.records
            .get(Collections.events, 'own')!
            .data[CalendarEvent.createdByKey],
        kid.id,
      );
      await write(mama, 'own', {
        ...appointment('Training (neu)', [kid.id]),
        CalendarEvent.createdByKey: mama.id,
      }, now + 1000);
      final after = app.records.get(Collections.events, 'own')!;
      expect(after.data['title'], 'Training (neu)');
      expect(after.data[CalendarEvent.createdByKey], kid.id);
    });

    test('a note by the child does not make the parents\' appointment '
        'the child\'s', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final secret = {
        ...appointment('Psychotherapie', [kid.id]),
        'confidential': true,
      };
      await write(mama, 'therapy', secret, now);
      await write(kid, 'therapy', {...secret, 'notes': 'Hefte'}, now + 1000);
      expect(app.records.get(Collections.events, 'therapy')!.updatedBy, kid.id);
      await write(kid, 'therapy', {
        ...secret,
        'notes': 'Hefte',
        'confidential': false,
      }, now + 2000);
      expect(
        app.records.get(Collections.events, 'therapy')!.data['confidential'],
        isTrue,
      );
      expect(await guestSeesTitle('therapy'), isFalse);
    });

    test('nor a family appointment the child changed once', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final family = appointment('Grillen', const []);
      await write(papa, 'bbq', family, now);
      await write(kid, 'bbq', {...family, 'notes': 'Würstchen'}, now + 1000);
      await write(kid, 'bbq', {
        ...family,
        'notes': 'Würstchen',
        'confidential': true,
      }, now + 2000);
      expect(
        app.records.get(Collections.events, 'bbq')!.data['confidential'],
        isNot(true),
      );
      expect(await guestSeesTitle('bbq'), isTrue);
    });

    test(
      'a child takes only itself out of the parents\' appointment',
      () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final both = appointment('Zahnarzt', [mama.id, kid.id]);
        await write(mama, 'dentist', both, now);
        await write(kid, 'dentist', {
          ...both,
          'memberIds': [kid.id],
        }, now + 1000);
        expect(
          app.records.get(Collections.events, 'dentist')!.data['memberIds'],
          [kid.id, mama.id],
        );
        await write(kid, 'dentist', {
          ...both,
          'memberIds': [kid.id],
          'confidential': true,
        }, now + 2000);
        expect(
          app.records.get(Collections.events, 'dentist')!.data['confidential'],
          isNot(true),
        );
        // Taking itself out stays possible.
        await write(kid, 'dentist', {
          ...both,
          'memberIds': [mama.id],
        }, now + 3000);
        expect(
          app.records.get(Collections.events, 'dentist')!.data['memberIds'],
          [mama.id],
        );
      },
    );

    test('nor does the bin make it the child\'s', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final secret = {
        ...appointment('Psychotherapie', [kid.id]),
        'confidential': true,
      };
      await write(mama, 'bin', secret, now);
      await sync(
        kid,
        changes: [
          SyncRecord(
            collection: Collections.events,
            id: 'bin',
            deleted: true,
            data: {
              'deletionSnapshot': {
                ...secret,
                CalendarEvent.createdByKey: kid.id,
              },
            },
            updatedAt: now + 1000,
            rev: app.records.get(Collections.events, 'bin')!.rev,
          ),
        ],
      );
      final bin = await call(mama, 'GET', 'api/trash');
      final item = (bin['items'] as List).cast<Map>().single;
      expect(
        (await call(
          mama,
          'POST',
          'api/trash/${item['id']}/restore',
          {},
        ))['_status'],
        200,
      );
      expect(
        app.records
            .get(Collections.events, 'bin')!
            .data[CalendarEvent.createdByKey],
        mama.id,
      );
    });

    test('an appointment from before the note has no owner', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = appointment('Kieferorthopäde', [kid.id]);
      await write(kid, 'old', old, now);
      // As stored by a server before the key.
      final stored = app.records.get(Collections.events, 'old')!;
      app.records.writeAsServer([
        stored.copyWith(
          data: {...stored.data}..remove(CalendarEvent.createdByKey),
          updatedAt: now + 500,
        ),
      ]);
      await write(kid, 'old', {...old, 'confidential': true}, now + 1000);
      expect(
        app.records.get(Collections.events, 'old')!.data['confidential'],
        isNot(true),
      );
    });
  });

  test('a child assigns no one outside a task\'s audience', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(
      mama,
      changes: [
        SyncRecord(
          collection: Collections.tasks,
          id: 't1',
          data: {
            'title': 'Geschenk für Papa',
            'assigneeId': kid.id,
            'assigneeIds': [kid.id],
            SyncRecord.visibilityKey: [mama.id, kid.id],
          },
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.tasks, 't1')!;
    await sync(
      kid,
      changes: [
        SyncRecord(
          collection: Collections.tasks,
          id: 't1',
          data: {
            'title': 'Geschenk für Papa',
            'assigneeId': kid.id,
            'assigneeIds': [kid.id, papa.id],
            SyncRecord.visibilityKey: [mama.id, kid.id],
          },
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    final after = app.records.get(Collections.tasks, 't1')!;
    expect(after.visibleTo, isNot(contains(papa.id)));
    expect(after.data['assigneeIds'], [kid.id]);
  });
}
