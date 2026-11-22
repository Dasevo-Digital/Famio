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

  /// As Famio's apps sync ([SyncRequest.resettable]); [fromApp] false for
  /// other clients, such as Home Assistant.
  Future<SyncResponse> sync(
    FamilyMember who, [
    List<SyncRecord> changes = const [],
    bool fromApp = true,
  ]) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(
          SyncRequest(since: 0, changes: changes, resettable: fromApp).toJson(),
        ),
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

  group('ticks written on an older version (#558)', () {
    Task packing(String id, {TaskRepeat? repeat, DateTime? due}) => Task(
      id: id,
      title: 'Koffer packen',
      assigneeIds: [oma.id],
      due: due,
      repeat: repeat,
      checklist: const [
        TaskStep(id: 's1', text: 'Pullover'),
        TaskStep(id: 's2', text: 'Socken'),
      ],
    );
    Task ticked(Task t, String step) => t.copyWith(
      checklist: [
        for (final s in t.checklist) s.id == step ? s.copyWith(done: true) : s,
      ],
    );

    test(
      'a step ticked offline does not reopen a task an adult finished',
      () async {
        await sync(mama, [rec(Collections.tasks, 't', packing('t').toData())]);
        final seen = stored('t');
        // Offline, the guest ticks one step only …
        final step = rec(
          Collections.tasks,
          't',
          ticked(Task.fromRecord(seen), 's1').toData(),
        ).copyWith(rev: seen.rev);
        // … meanwhile an adult ticks off the whole task.
        await sync(mama, [
          rec(
            Collections.tasks,
            't',
            Task.fromRecord(seen).completed().toData(),
          ),
        ]);
        final done = stored('t');
        final r = await sync(oma, [step]);
        final after = Task.fromRecord(stored('t'));
        expect(after.done, isTrue);
        expect(after.completedAt, Task.fromRecord(done).completedAt);
        expect([for (final s in after.checklist) s.done], [true, false]);
        expect(app.records.all(Collections.conflicts), isEmpty);
        expect(r.refused, isEmpty, reason: 'nothing of the guest left out');
      },
    );

    test('steps count one by one: an adult\'s tick meanwhile stays', () async {
      await sync(mama, [rec(Collections.tasks, 't', packing('t').toData())]);
      final seen = stored('t');
      final step = rec(
        Collections.tasks,
        't',
        ticked(Task.fromRecord(seen), 's2').toData(),
      ).copyWith(rev: seen.rev);
      await sync(mama, [
        rec(
          Collections.tasks,
          't',
          ticked(Task.fromRecord(seen), 's1').toData(),
        ),
      ]);
      await sync(oma, [step]);
      final after = Task.fromRecord(stored('t'));
      expect([for (final s in after.checklist) s.done], [true, true]);
      expect(after.done, isFalse);
    });

    test(
      'a step ticked offline keeps the due date a repeating task moved to',
      () async {
        await sync(mama, [
          rec(
            Collections.tasks,
            'w',
            packing(
              'w',
              repeat: TaskRepeat.weekly,
              due: DateTime.now(),
            ).toData(),
          ),
        ]);
        final seen = stored('w');
        final step = rec(
          Collections.tasks,
          'w',
          ticked(Task.fromRecord(seen), 's1').toData(),
        ).copyWith(rev: seen.rev);
        await sync(mama, [
          rec(
            Collections.tasks,
            'w',
            Task.fromRecord(seen).completed().toData(),
          ),
        ]);
        final moved = Task.fromRecord(stored('w')).due;
        await sync(oma, [step]);
        expect(Task.fromRecord(stored('w')).due, moved);
      },
    );

    test(
      'a guest who ticked off a repeating task offline moves it on',
      () async {
        await sync(mama, [
          rec(
            Collections.tasks,
            'w',
            packing(
              'w',
              repeat: TaskRepeat.weekly,
              due: DateTime.now(),
            ).toData(),
          ),
        ]);
        final seen = stored('w');
        final tick = rec(
          Collections.tasks,
          'w',
          Task.fromRecord(seen).completed().toData(),
        ).copyWith(rev: seen.rev);
        await sync(mama, [
          rec(Collections.tasks, 'w', {...seen.data, 'title': 'Koffer'}),
        ]);
        await sync(oma, [tick]);
        final after = stored('w');
        expect(
          Task.fromRecord(after).due,
          Task.fromRecord(tick).due,
          reason: 'the tick is theirs, the rename is not',
        );
        expect(after.data['title'], 'Koffer');
      },
    );
  });

  test('a repeating task moves on only when it is ticked off (#477)', () async {
    await sync(mama, [
      rec(
        Collections.tasks,
        'w',
        Task(
          id: 'w',
          title: 'Blumen gießen',
          assigneeIds: [oma.id],
          due: DateTime.now(),
          repeat: TaskRepeat.weekly,
        ).toData(),
      ),
    ]);
    final seen = stored('w');
    final r = await sync(oma, [
      rec(Collections.tasks, 'w', {
        ...seen.data,
        'due': DateTime(2099).toIso8601String(),
      }),
    ]);
    expect(stored('w').data['due'], seen.data['due']);
    expect(r.refused.single.code, 'partly_kept');
  });

  group('Home Assistant with "tick off and shopping"', () {
    // Not Famio's app: it sends no `resettable` and no base version.
    SyncRecord fromHa(String id, Map<String, Object?> data) =>
        rec(Collections.tasks, id, data).copyWith(rev: 0);

    test(
      'a rename with the tick: the tick stays, the rest is reported',
      () async {
        await sync(mama, [
          rec(
            Collections.tasks,
            'h',
            Task(id: 'h', title: 'Müll', assigneeIds: [kind.id]).toData(),
          ),
        ]);
        final seen = stored('h');
        final r = await sync(wall, [
          fromHa('h', {
            ...seen.data,
            'title': 'Altpapier',
            'done': true,
            'completedAt': DateTime.now().toIso8601String(),
          }),
        ], false);
        expect(stored('h').data['title'], 'Müll');
        expect(stored('h').data['done'], isTrue);
        expect(r.refused.map((i) => (i.id, i.code)), [('h', 'partly_kept')]);

        // Only a tick: nothing to report.
        final tick = await sync(wall, [
          fromHa('h', {
            ...stored('h').data,
            'done': false,
            'completedAt': null,
          }),
        ], false);
        expect(tick.refused, isEmpty);
        expect(stored('h').data['done'], isFalse);
      },
    );

    test('a due date without a tick moves no repeating task', () async {
      await sync(mama, [
        rec(
          Collections.tasks,
          'w',
          Task(
            id: 'w',
            title: 'Müll',
            due: DateTime.now(),
            repeat: TaskRepeat.weekly,
          ).toData(),
        ),
      ]);
      final seen = stored('w');
      final r = await sync(wall, [
        fromHa('w', {...seen.data, 'due': DateTime(2099).toIso8601String()}),
      ], false);
      expect(stored('w').data['due'], seen.data['due']);
      expect(r.refused.single.code, 'partly_kept');
    });
  });
}
