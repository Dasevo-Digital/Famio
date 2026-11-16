import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Who sees the household book is set in its settings, and the server keeps
/// to it, whoever writes an entry (#538). Family calendar subscriptions
/// without an owner are the adults'.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, kid, ha;
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
    ha = app.accounts.create(
      username: 'homeassistant',
      displayName: 'Home Assistant',
      role: MemberRole.service,
    );
    tokens = {
      for (final m in [mama, papa, kid, ha])
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
    expect(response.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await response.readAsString()) as Map).cast(),
    );
  }

  var clock = DateTime.now().millisecondsSinceEpoch;
  int tick() => clock += 1000;

  SyncRecord settings(List<String> members) => SyncRecord(
    collection: Collections.budgetSettings,
    id: BudgetSettings.recordId,
    data: {
      ...BudgetSettings(memberIds: members).toData(),
      SyncRecord.visibilityKey: members.isEmpty ? null : members,
    },
    updatedAt: tick(),
    rev:
        app.records
            .get(Collections.budgetSettings, BudgetSettings.recordId)
            ?.rev ??
        0,
  );

  SyncRecord entry(String id, {List<String>? visibleTo}) => SyncRecord(
    collection: Collections.budgetEntries,
    id: id,
    data: {
      'date': '2026-11-15',
      'cents': 1250,
      'category': 'Lebensmittel',
      SyncRecord.visibilityKey: ?visibleTo,
    },
    updatedAt: tick(),
    rev: app.records.get(Collections.budgetEntries, id)?.rev ?? 0,
  );

  Set<String> live(SyncResponse r, String collection) => {
    for (final c in r.changes)
      if (c.collection == collection && !c.deleted) c.id,
  };

  test(
    'moving an entry along to new settings keeps who wrote it (#552)',
    () async {
      await sync(papa, changes: [entry('vom-papa')]);
      expect(
        app.records.get(Collections.budgetEntries, 'vom-papa')!.visibleTo,
        isNull,
      );
      // An older app moves every entry itself, in the name of whoever
      // changed the settings: the server keeps the entry Papa's.
      final moved = entry('vom-papa', visibleTo: [mama.id]);
      final answer = await sync(
        mama,
        changes: [
          settings([mama.id]),
          moved,
        ],
      );
      final stored = app.records.get(Collections.budgetEntries, 'vom-papa')!;
      expect(stored.updatedBy, papa.id);
      expect(stored.visibleTo, unorderedEquals([mama.id, papa.id]));
      expect(answer.refused, isEmpty);
      expect(live(await sync(papa), Collections.budgetEntries), {'vom-papa'});
      // A real change is still Mama's.
      final changed = entry('vom-papa', visibleTo: [mama.id]);
      await sync(
        mama,
        changes: [
          changed.copyWith(data: {...changed.data, 'cents': 990}),
        ],
      );
      final after = app.records.get(Collections.budgetEntries, 'vom-papa')!;
      expect(after.updatedBy, mama.id);
      expect(after.data['cents'], 990);
    },
  );

  test('an adult outside a restricted household book writes into it, '
      'not to the family (HAU-162)', () async {
    await sync(
      mama,
      changes: [
        settings([mama.id]),
      ],
    );
    // Papa's app has no settings and sets no audience.
    await sync(papa, changes: [entry('bei-papa')]);
    final stored = app.records.get(Collections.budgetEntries, 'bei-papa')!;
    expect(stored.visibleTo, unorderedEquals([mama.id, papa.id]));
    expect(live(await sync(kid), Collections.budgetEntries), isEmpty);
    expect(live(await sync(ha), Collections.budgetEntries), isEmpty);
    expect(live(await sync(mama), Collections.budgetEntries), {'bei-papa'});
    // An app may not open it to the family either.
    await sync(kid, changes: [entry('vom-kind', visibleTo: null)]);
    expect(
      app.records.get(Collections.budgetEntries, 'vom-kind')!.visibleTo,
      unorderedEquals([mama.id, kid.id]),
    );
    // Papa keeps his own entry, the child's does not reach him.
    expect(live(await sync(papa), Collections.budgetEntries), {'bei-papa'});
  });

  test('the service account gets an open household book, not a restricted '
      'one (HAU-160)', () async {
    await sync(mama, changes: [entry('offen')]);
    expect(
      app.records.get(Collections.budgetEntries, 'offen')!.visibleTo,
      isNull,
    );
    final open = await sync(ha);
    expect(live(open, Collections.budgetEntries), {'offen'});
    expect(live(await sync(kid), Collections.budgetEntries), {'offen'});

    await sync(
      mama,
      changes: [
        settings([mama.id, papa.id]),
      ],
    );
    final restricted = await sync(ha, since: open.rev);
    expect(live(restricted, Collections.budgetEntries), isEmpty);
    expect(
      restricted.changes.where(
        (c) => c.collection == Collections.budgetEntries && c.deleted,
      ),
      isNotEmpty,
      reason: 'the service account lets go of what it had',
    );
    expect(live(await sync(ha), Collections.budgetEntries), isEmpty);
  });

  test('new settings move entries the app did not move along', () async {
    await sync(papa, changes: [entry('alt')]);
    final before = await sync(kid);
    expect(live(before, Collections.budgetEntries), {'alt'});
    // Only the settings (an older app, or a later batch with the entries).
    await sync(
      mama,
      changes: [
        settings([mama.id]),
      ],
    );
    expect(
      app.records.get(Collections.budgetEntries, 'alt')!.visibleTo,
      unorderedEquals([mama.id, papa.id]),
    );
    final after = await sync(kid, since: before.rev);
    expect(
      after.changes.any(
        (c) =>
            c.collection == Collections.budgetEntries &&
            c.id == 'alt' &&
            c.deleted,
      ),
      isTrue,
    );
    // Open again: the family sees it again.
    await sync(mama, changes: [settings([])]);
    expect(
      app.records.get(Collections.budgetEntries, 'alt')!.visibleTo,
      isNull,
    );
    expect(live(await sync(kid), Collections.budgetEntries), {'alt'});
  });

  test(
    'settings gone with the only member who saw the book open nothing',
    () async {
      await sync(
        mama,
        changes: [
          settings([mama.id]),
        ],
      );
      await sync(papa, changes: [entry('bei-papa')]);
      app.records.purgeMember(mama.id);
      expect(
        app.records.get(Collections.budgetEntries, 'bei-papa')!.visibleTo,
        unorderedEquals([mama.id, papa.id]),
      );
      expect(live(await sync(kid), Collections.budgetEntries), isEmpty);
      expect(live(await sync(ha), Collections.budgetEntries), isEmpty);
      expect(live(await sync(papa), Collections.budgetEntries), {'bei-papa'});
    },
  );

  test('entries an older server kept open follow the settings once', () async {
    await sync(
      mama,
      changes: [
        settings([mama.id]),
      ],
    );
    // As stored before the server set the audience itself (HAU-162).
    app.records.writeAsServer([
      SyncRecord(
        collection: Collections.budgetEntries,
        id: 'alt-offen',
        data: const {
          'date': '2026-11-01',
          'cents': 900,
          'category': 'Sonstiges',
        },
        updatedAt: tick(),
      ),
    ]);
    expect(
      app.records.get(Collections.budgetEntries, 'alt-offen')!.visibleTo,
      isNull,
    );
    app.db.execute('DELETE FROM settings WHERE key = ?', ['budgetAudience1']);
    app.records.followBudgetSettings();
    // Written by the server: only the household book's members.
    expect(app.records.get(Collections.budgetEntries, 'alt-offen')!.visibleTo, [
      mama.id,
    ]);
    expect(live(await sync(kid), Collections.budgetEntries), isEmpty);
    expect(live(await sync(ha), Collections.budgetEntries), isEmpty);
  });

  test('a subscription goes where the household book goes', () async {
    await sync(
      mama,
      changes: [
        settings([mama.id]),
      ],
    );
    await sync(
      papa,
      changes: [
        SyncRecord(
          collection: Collections.subscriptions,
          id: 'streaming',
          data: {
            'name': 'Streaming',
            'cents': 1299,
            'start': '2026-01-01',
            'every': 1,
            'unit': 'months',
          },
          updatedAt: tick(),
        ),
      ],
    );
    final stored = app.records.get(Collections.subscriptions, 'streaming');
    expect(stored, isNotNull);
    expect(stored!.visibleTo, unorderedEquals([mama.id, papa.id]));
  });

  group('family calendar subscriptions (KAL-128)', () {
    SyncRecord subscription(
      String id,
      String name, {
      String? ownerId,
      bool deleted = false,
    }) => SyncRecord(
      collection: Collections.calendarSubscriptions,
      id: id,
      data: deleted
          ? const {}
          : CalendarSubscription(
              id: id,
              name: name,
              url: 'https://ferien.example.com/ferien.ics',
              ownerId: ownerId,
            ).toData(),
      deleted: deleted,
      updatedAt: tick(),
      rev: app.records.get(Collections.calendarSubscriptions, id)?.rev ?? 0,
    );

    test('a child neither renames nor removes one without an owner', () async {
      await sync(mama, changes: [subscription('ferien', 'Schulferien')]);
      final rejected = await sync(
        kid,
        changes: [subscription('ferien', 'Meine Ferien')],
      );
      expect(
        rejected.rejected.single.data['name'],
        'Schulferien',
        reason: 'the device gets the stored version back',
      );
      // And learns that it was not allowed (#539).
      expect(rejected.refused.single.id, 'ferien');
      expect(rejected.refused.single.code, 'not_allowed');
      await sync(kid, changes: [subscription('ferien', '', deleted: true)]);
      final stored = app.records.get(
        Collections.calendarSubscriptions,
        'ferien',
      )!;
      expect(stored.deleted, isFalse);
      expect(stored.data['name'], 'Schulferien');
      expect(stored.data['ownerId'], isNull);
    });

    test('a lost conflict is no refusal (#539)', () async {
      await sync(mama, changes: [subscription('ferien', 'Schulferien')]);
      final older = subscription('ferien', 'Älter');
      await sync(mama, changes: [subscription('ferien', 'Neuer')]);
      final answer = await sync(
        papa,
        changes: [older.copyWith(updatedAt: older.updatedAt - 10000)],
      );
      expect(answer.rejected, isNotEmpty);
      expect(answer.refused, isEmpty);
    });

    test('an adult may change it', () async {
      await sync(mama, changes: [subscription('ferien', 'Schulferien')]);
      await sync(papa, changes: [subscription('ferien', 'Ferien Berlin')]);
      expect(
        app.records
            .get(Collections.calendarSubscriptions, 'ferien')!
            .data['name'],
        'Ferien Berlin',
      );
    });

    test('one a child adds is its own', () async {
      await sync(kid, changes: [subscription('fussball', 'Fußball')]);
      final stored = app.records.get(
        Collections.calendarSubscriptions,
        'fussball',
      )!;
      expect(stored.data['ownerId'], kid.id);
      await sync(kid, changes: [subscription('fussball', 'Fußball A-Jugend')]);
      expect(
        app.records
            .get(Collections.calendarSubscriptions, 'fussball')!
            .data['name'],
        'Fußball A-Jugend',
      );
    });
  });
}
