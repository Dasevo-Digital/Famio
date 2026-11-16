import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Guests change and delete the tasks they created themselves; of all
/// others only their ticks count (#365). Who created a task the server
/// keeps itself, like who entered an appointment.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, oma;
  late Map<String, String> tokens;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
    oma = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    tokens = {
      for (final m in [mama, papa, oma]) m.id: app.accounts.createSession(m.id),
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
  }) async {
    final r = await call(
      who,
      'POST',
      'api/sync',
      body: SyncRequest(since: 0, changes: changes).toJson(),
    );
    expect(r.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    );
  }

  SyncRecord task(
    String id,
    String title, {
    List<String> assignees = const [],
    List<String>? visibleTo,
    bool done = false,
    Map<String, Object?> extra = const {},
  }) => SyncRecord(
    collection: Collections.tasks,
    id: id,
    data: {
      ...Task(
        id: id,
        title: title,
        done: done,
        assigneeIds: assignees,
        visibleTo: visibleTo,
      ).toData(),
      ...extra,
    },
    updatedAt: clock += 1000,
    rev: app.records.get(Collections.tasks, id)?.rev ?? 0,
  );

  SyncRecord gone(String id) => SyncRecord(
    collection: Collections.tasks,
    id: id,
    data: const {},
    deleted: true,
    updatedAt: clock += 1000,
    rev: app.records.get(Collections.tasks, id)?.rev ?? 0,
  );

  SyncRecord stored(String id) => app.records.get(Collections.tasks, id)!;

  Future<bool> has(FamilyMember who, String id) async =>
      (await sync(who)).changes.any((r) => r.id == id && !r.deleted);

  test('the server notes who created a task, whatever an app says', () async {
    await sync(
      oma,
      changes: [
        task('own', 'Kuchen backen', extra: {Task.createdByKey: mama.id}),
      ],
    );
    expect(stored('own').data[Task.createdByKey], oma.id);
    await sync(
      mama,
      changes: [
        task('fam', 'Rasen mähen', extra: {Task.createdByKey: oma.id}),
      ],
    );
    expect(stored('fam').data[Task.createdByKey], mama.id);
    // Changes keep it, also when an app leaves it out or sends another.
    await sync(mama, changes: [task('own', 'Kuchen backen (Mama)')]);
    expect(stored('own').data[Task.createdByKey], oma.id);
    await sync(
      papa,
      changes: [
        task('fam', 'Rasen mähen', extra: {Task.createdByKey: papa.id}),
      ],
    );
    expect(stored('fam').data[Task.createdByKey], mama.id);
  });

  test('a guest changes an own task completely', () async {
    await sync(oma, changes: [task('own', 'Kuchen backen')]);
    final answer = await sync(
      oma,
      changes: [
        task('own', 'Apfelkuchen backen', assignees: [mama.id]),
      ],
    );
    expect(answer.refused, isEmpty);
    final t = Task.fromRecord(stored('own'));
    expect(t.title, 'Apfelkuchen backen');
    expect(t.assigneeIds, [mama.id]);
    // One for the family stays visible to the guest who wrote it.
    expect(t.visibleTo, contains(oma.id));
    expect(await has(oma, 'own'), isTrue);
    expect(await has(papa, 'own'), isTrue);
    // No copy of a conflict with itself.
    expect(app.records.all(Collections.conflicts), isEmpty);
  });

  test('a guest deletes an own task, and gets it back', () async {
    await sync(oma, changes: [task('own', 'Kuchen backen')]);
    final deleted = await sync(oma, changes: [gone('own')]);
    expect(deleted.refused, isEmpty);
    expect(stored('own').deleted, isTrue);
    expect(app.records.trashFor(oma.id).$1.single.title, 'Kuchen backen');
    // "Rückgängig": the same id again, still the guest's own.
    await sync(oma, changes: [task('own', 'Kuchen backen')]);
    expect(stored('own').deleted, isFalse);
    expect(stored('own').data[Task.createdByKey], oma.id);
    await sync(oma, changes: [task('own', 'Zwei Kuchen backen')]);
    expect(stored('own').data['title'], 'Zwei Kuchen backen');
  });

  test('of a task someone else created, a guest only ticks off', () async {
    await sync(
      mama,
      changes: [
        task('fam', 'Rasen mähen', assignees: [oma.id]),
      ],
    );
    final renamed = await sync(
      oma,
      changes: [
        task('fam', 'Hecke schneiden', assignees: [oma.id]),
      ],
    );
    expect(renamed.refused.single.code, 'partly_kept');
    expect(stored('fam').data['title'], 'Rasen mähen');
    final ticked = await sync(
      oma,
      changes: [
        task('fam', 'Rasen mähen', assignees: [oma.id], done: true),
      ],
    );
    // Only the tick: nothing to tell, though the app knew no creator.
    expect(ticked.refused, isEmpty);
    expect(stored('fam').data['done'], isTrue);
    final deleted = await sync(oma, changes: [gone('fam')]);
    expect(deleted.refused.single.code, 'not_allowed');
    expect(stored('fam').deleted, isFalse);
  });

  test(
    'a task from before the creator was noted is not the guest\'s',
    () async {
      await sync(oma, changes: [task('old', 'Kuchen backen')]);
      // As stored by an older server.
      app.db.execute(
        "UPDATE records SET data = json_remove(data, '\$.${Task.createdByKey}')"
        " WHERE collection = 'tasks' AND id = 'old'",
      );
      await sync(oma, changes: [task('old', 'Torte backen')]);
      expect(stored('old').data['title'], 'Kuchen backen');
      expect(stored('old').data.containsKey(Task.createdByKey), isFalse);
      await sync(oma, changes: [gone('old')]);
      expect(stored('old').deleted, isFalse);
    },
  );

  test(
    'written again over its deletion, a family task stays the family\'s',
    () async {
      await sync(
        mama,
        changes: [
          task('fam', 'Rasen mähen', assignees: [oma.id]),
        ],
      );
      await sync(mama, changes: [gone('fam')]);
      // A guest's device writes it again, with other contents.
      await sync(
        oma,
        changes: [
          task('fam', 'Hecke schneiden', assignees: [oma.id], done: true),
        ],
      );
      final back = stored('fam');
      expect(back.deleted, isFalse);
      expect(back.data['title'], 'Rasen mähen');
      expect(back.data['done'], isTrue);
      expect(back.data[Task.createdByKey], mama.id);
      // So it is no own task of the guest's afterwards either.
      await sync(oma, changes: [gone('fam')]);
      expect(stored('fam').deleted, isFalse);
    },
  );

  test(
    'over a deletion whose task left the bin, what is written is new',
    () async {
      await sync(
        mama,
        changes: [
          task('fam', 'Rasen mähen', assignees: [oma.id]),
        ],
      );
      await sync(mama, changes: [gone('fam')]);
      app.db.execute('DELETE FROM trash');
      await sync(oma, changes: [task('fam', 'Kuchen backen')]);
      expect(stored('fam').data['title'], 'Kuchen backen');
      expect(stored('fam').data[Task.createdByKey], oma.id);
    },
  );
}
