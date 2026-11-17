import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Ticks of a wall display (#556) and of a guest who ticked offline (#558):
/// written as the apps write them, whole tasks from what they have stored.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, kind, oma, wall;
  late Map<String, String> tokens;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    kind = app.accounts.create(
      username: 'kind',
      displayName: 'Kind',
      role: MemberRole.child,
    );
    oma = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    wall = app.accounts.create(
      username: 'wand',
      displayName: 'Wand',
      role: MemberRole.service,
    );
    app.accounts.update(wall.id, serviceAccess: ServiceAccess.everyday);
    tokens = {
      for (final m in [mama, kind, oma, wall])
        m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<SyncResponse> sync(
    FamilyMember who, [
    List<SyncRecord> changes = const [],
  ]) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(SyncRequest(since: 0, changes: changes).toJson()),
      ),
    );
    expect(r.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    );
  }

  SyncRecord rec(String c, String id, Map<String, Object?> data) => SyncRecord(
    collection: c,
    id: id,
    data: data,
    updatedAt: clock += 1000,
    rev: app.records.get(c, id)?.rev ?? 0,
  );
  SyncRecord stored(String id) => app.records.get(Collections.tasks, id)!;

  group('wall display (#556)', () {
    test('ticks a repeating task: it moves on', () async {
      final due = DateTime.now();
      await sync(mama, [
        rec(
          Collections.tasks,
          'weekly',
          Task(
            id: 'weekly',
            title: 'Müll raus',
            assigneeIds: [kind.id],
            due: due,
            repeat: TaskRepeat.weekly,
          ).toData(),
        ),
      ]);
      final before = stored('weekly');
      final r = await sync(wall, [
        rec(
          Collections.tasks,
          'weekly',
          Task.fromRecord(before).completed().toData(),
        ),
      ]);
      expect(r.refused, isEmpty);
      final after = stored('weekly');
      expect(after.rev, greaterThan(before.rev));
      expect(
        Task.fromRecord(after).due!.isAfter(due.add(const Duration(days: 6))),
        isTrue,
      );
      expect(after.data['title'], 'Müll raus');
    });

    test('ticks a task Home Assistant wrote with fewer fields', () async {
      await sync(mama, [
        rec(Collections.tasks, 'ha', {
          'title': 'Altpapier',
          'notes': '',
          'done': false,
          'due': null,
          'assigneeId': kind.id,
          'completedAt': null,
          'createdAt': DateTime.now().toIso8601String(),
          'remindAt': null,
        }),
      ]);
      final before = stored('ha');
      final r = await sync(wall, [
        rec(
          Collections.tasks,
          'ha',
          Task.fromRecord(before).completed().toData(),
        ),
      ]);
      expect(r.refused, isEmpty);
      final after = stored('ha');
      expect(after.data['done'], isTrue);
      // Nothing else of the task changes, also not the fields it lacked.
      expect(after.data.containsKey('assigneeIds'), isFalse);
      expect(after.data['title'], 'Altpapier');
    });

    test('changes nothing else of a task and adds none', () async {
      await sync(mama, [
        rec(
          Collections.tasks,
          'once',
          Task(id: 'once', title: 'Pflanzen', assigneeIds: [kind.id]).toData(),
        ),
      ]);
      final before = stored('once');
      final r = await sync(wall, [
        rec(Collections.tasks, 'once', {
          ...Task.fromRecord(before).completed().toData(),
          'title': 'Umbenannt',
          'assigneeIds': [mama.id],
          'assigneeId': mama.id,
        }),
        rec(
          Collections.tasks,
          'new',
          Task(id: 'new', title: 'Neu von der Wand').toData(),
        ),
      ]);
      // The screen offers only ticking: nothing to tell about.
      expect(r.refused.map((i) => i.id), ['new']);
      final after = stored('once');
      expect(after.data['done'], isTrue);
      expect(after.data['title'], 'Pflanzen');
      expect(Task.assigneesIn(after.data), [kind.id]);
      expect(app.records.get(Collections.tasks, 'new'), isNull);
    });
  });

  test('a guest who ticked offline keeps the tick when an adult changed the '
      'task meanwhile (#558)', () async {
    await sync(mama, [
      rec(
        Collections.tasks,
        't',
        Task(id: 't', title: 'Tropfen geben', assigneeIds: [oma.id]).toData(),
      ),
    ]);
    final seen = stored('t');
    // Ticked offline now …
    final tick = rec(
      Collections.tasks,
      't',
      Task.fromRecord(seen).completed().toData(),
    ).copyWith(rev: seen.rev);
    // … the adult renames it later, before the guest's phone syncs.
    await sync(mama, [
      rec(Collections.tasks, 't', {
        ...seen.data,
        'title': 'Tropfen geben (3 Stück)',
      }),
    ]);
    final renamed = stored('t');
    final r = await sync(oma, [tick]);
    final after = stored('t');
    expect(after.data['done'], isTrue);
    expect(after.data['title'], 'Tropfen geben (3 Stück)');
    expect(after.updatedAt, greaterThan(renamed.updatedAt));
    expect(app.records.all(Collections.conflicts), isEmpty);
    expect(r.rejected, isEmpty);
    // The guest's device gets the task as it is now.
    final back = r.changes.where((c) => c.id == 't').single;
    expect(back.data['title'], 'Tropfen geben (3 Stück)');
  });

  test('a guest editing their own task offline still loses against a newer '
      'change (control)', () async {
    final r0 = await sync(oma, [
      rec(Collections.tasks, 'own', Task(id: 'own', title: 'Eigene').toData()),
    ]);
    expect(r0.refused, isEmpty);
    final seen = stored('own');
    final late = rec(Collections.tasks, 'own', {
      ...seen.data,
      'title': 'Eigene (Oma)',
    }).copyWith(rev: seen.rev);
    await sync(mama, [
      rec(Collections.tasks, 'own', {...seen.data, 'title': 'Eigene (Mama)'}),
    ]);
    await sync(oma, [late.copyWith(updatedAt: seen.updatedAt + 1)]);
    expect(stored('own').data['title'], 'Eigene (Mama)');
    expect(app.records.all(Collections.conflicts), hasLength(1));
  });
}
