import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/api_exception.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  late FamioServerApp app;
  late FamilyMember owner, other;
  setUp(() {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    other = app.accounts.create(username: 'other', displayName: 'Other');
  });

  test('a stale offline deletion cannot replace a newer server snapshot', () {
    const original = SyncRecord(
      collection: Collections.notes,
      id: 'note',
      data: {'title': 'Original'},
      updatedAt: 1,
    );
    app.records.writeAs(owner.id, [original]);
    final base = app.records.get(Collections.notes, 'note')!;
    app.records.writeAs(other.id, [
      base.copyWith(data: {'title': 'New server version'}, updatedAt: 2),
    ]);
    app.records.writeAs(owner.id, [
      base.copyWith(
        deleted: true,
        updatedAt: 3,
        data: {
          'deletionSnapshot': {'title': 'Old offline draft'},
        },
      ),
    ]);
    expect(
      app.records.trashFor(owner.id).$1.single.title,
      'New server version',
    );
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  void save(String collection, String id, Map<String, Object?> data) =>
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: collection,
          id: id,
          data: data,
          updatedAt: (app.records.get(collection, id)?.updatedAt ?? 0) + 1,
        ),
      ]);
  void remove(String collection, String id) => app.records.writeAs(owner.id, [
    SyncRecord(
      collection: collection,
      id: id,
      data: const {},
      deleted: true,
      updatedAt: app.records.get(collection, id)!.updatedAt + 1,
    ),
  ]);
  Future<(int, Map)> call(String who, String method, String path) async {
    final token = app.accounts.createSession(who);
    final result = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/$path'),
        headers: {'authorization': 'Bearer $token'},
      ),
    );
    return (result.statusCode, jsonDecode(await result.readAsString()) as Map);
  }

  test(
    'another device lists and restores the latest snapshot exactly once',
    () async {
      save(Collections.notes, 'note', {'title': 'First', 'ext:kept': 'value'});
      save(Collections.notes, 'note', {'title': 'Latest', 'ext:kept': 'value'});
      remove(Collections.notes, 'note');
      final (status, body) = await call(other.id, 'GET', 'api/trash');
      expect(status, 200);
      final entry = TrashEntry.fromJson(
        (body['items'] as List).single.cast<String, Object?>(),
      );
      expect(entry.title, 'Latest');
      expect(entry.canRestore, isTrue);
      expect(
        entry.expiresAt.difference(entry.deletedAt),
        const Duration(days: 30),
      );
      expect(
        (await call(other.id, 'POST', 'api/trash/${entry.id}/restore')).$1,
        200,
      );
      final restored = app.records.get(Collections.notes, 'note')!;
      expect(restored.deleted, isFalse);
      expect(restored.data['ext:kept'], 'value');
      expect(restored.updatedBy, other.id);
      expect(
        (await call(owner.id, 'POST', 'api/trash/${entry.id}/restore')).$1,
        404,
      );
      expect(app.records.trashFor(owner.id).$1, isEmpty);
    },
  );

  test(
    'private snapshots and role changes do not regain read or restore rights',
    () async {
      save(Collections.notes, 'note', {
        'title': 'Private',
        'visibleTo': [owner.id],
      });
      remove(Collections.notes, 'note');
      final entry = app.records.trashFor(owner.id).$1.single;
      expect(app.records.trashFor(other.id).$1, isEmpty);
      expect(
        (await call(other.id, 'POST', 'api/trash/${entry.id}/restore')).$1,
        404,
      );
      save(Collections.documents, 'doc', {'title': 'Document'});
      remove(Collections.documents, 'doc');
      final document = app.records.trashFor(owner.id).$1.first;
      app.accounts.update(owner.id, role: MemberRole.guest);
      expect(
        app.records
            .trashFor(owner.id)
            .$1
            .any((e) => e.record.collection == Collections.documents),
        isFalse,
      );
      expect(
        (await call(owner.id, 'POST', 'api/trash/${document.id}/restore')).$1,
        404,
      );
    },
  );

  test(
    'a guest sees assigned deleted tasks but cannot restore read-only notes',
    () async {
      app.accounts.update(other.id, role: MemberRole.guest);
      save(
        Collections.tasks,
        'task',
        Task(id: 'task', title: 'For guest', assigneeIds: [other.id]).toData(),
      );
      save(Collections.notes, 'note', {
        'title': 'Visible note',
        'visibleTo': [owner.id, other.id],
      });
      remove(Collections.tasks, 'task');
      remove(Collections.notes, 'note');
      final (_, body) = await call(other.id, 'GET', 'api/trash');
      final entries = [
        for (final item in body['items'] as List)
          TrashEntry.fromJson((item as Map).cast()),
      ];
      expect(entries, hasLength(2));
      final note = entries.firstWhere(
        (e) => e.record.collection == Collections.notes,
      );
      expect(note.canRestore, isFalse);
      expect(
        (await call(other.id, 'POST', 'api/trash/${note.id}/restore')).$1,
        403,
      );
      final task = entries.firstWhere(
        (e) => e.record.collection == Collections.tasks,
      );
      expect(task.canRestore, isTrue);
      expect(
        (await call(other.id, 'POST', 'api/trash/${task.id}/restore')).$1,
        200,
      );
    },
  );

  test(
    'a new live version removes the obsolete snapshot and cannot be overwritten',
    () async {
      save(Collections.notes, 'note', {'title': 'Deleted'});
      remove(Collections.notes, 'note');
      final id = app.records.trashFor(owner.id).$1.single.id;
      save(Collections.notes, 'note', {'title': 'Recreated'});
      expect((await call(owner.id, 'POST', 'api/trash/$id/restore')).$1, 404);
      expect(
        app.records.get(Collections.notes, 'note')!.data['title'],
        'Recreated',
      );
    },
  );

  test(
    'attachments stay accessible and retained only until trash expiry',
    () async {
      final uploaded = await app.files.save(
        owner: owner.id,
        name: 'fixture.txt',
        mime: 'text/plain',
        body: Stream.value([1, 2, 3]),
      );
      final file = FileRef(
        id: uploaded.id,
        name: uploaded.name,
        mime: uploaded.mime,
        size: uploaded.size,
      );
      save(
        Collections.documents,
        'doc',
        FamilyDocument(
          id: 'doc',
          title: 'With file',
          category: DocumentCategory.other,
          file: file,
          visibleTo: [owner.id, other.id],
        ).toData(),
      );
      remove(Collections.documents, 'doc');
      app.db.execute('UPDATE files SET created_at = 0');
      expect(app.files.mayRead(uploaded, other.id), isTrue);
      expect(app.files.collectGarbage(), 0);
      app.db.execute('UPDATE trash SET expires_at = 0');
      expect(app.files.mayRead(uploaded, other.id), isFalse);
      expect(app.records.expireTrash(), 1);
      expect(app.files.collectGarbage(), 1);
      expect(app.files.get(uploaded.id), isNull);
    },
  );

  test('wipe also clears deletion snapshots', () {
    save(Collections.notes, 'note', {'title': 'Deleted'});
    remove(Collections.notes, 'note');
    app.records.wipe();
    expect(app.records.trashFor(owner.id).$1, isEmpty);
    expect(app.db.select('SELECT * FROM trash'), isEmpty);
  });

  test(
    'a second offline deletion preserves restoration and the original expiry',
    () {
      save(Collections.notes, 'note', {'title': 'Keep deletion snapshot'});
      remove(Collections.notes, 'note');
      final before = app.records.trashFor(owner.id).$1.single;
      remove(Collections.notes, 'note');
      final after = app.records.trashFor(owner.id).$1.single;
      expect(after.id, before.id);
      expect(after.expiresAt, before.expiresAt);
      app.records.restoreTrash(owner.id, after.id);
      expect(app.records.get(Collections.notes, 'note')!.deleted, isFalse);
    },
  );

  test(
    'a forged offline deletion snapshot never grants foreign file access',
    () async {
      final file = await app.files.save(
        owner: owner.id,
        name: 'private.txt',
        mime: 'text/plain',
        body: Stream.value([1]),
      );
      app.records.writeAs(other.id, [
        SyncRecord(
          collection: Collections.documents,
          id: 'forged',
          updatedAt: 1,
          deleted: true,
          data: {
            'deletionSnapshot': {
              'title': 'Forged',
              'file': {
                'id': file.id,
                'name': file.name,
                'mime': file.mime,
                'size': file.size,
              },
            },
          },
        ),
      ]);
      expect(app.records.trashFor(other.id).$1, isEmpty);
      expect(app.files.mayRead(file, other.id), isFalse);
    },
  );

  test('read-only service accounts cannot restore deleted records', () async {
    save(Collections.notes, 'note', {'title': 'Visible'});
    remove(Collections.notes, 'note');
    app.accounts.update(
      other.id,
      role: MemberRole.service,
      serviceAccess: ServiceAccess.readOnly,
    );
    final (_, body) = await call(other.id, 'GET', 'api/trash');
    final entry = TrashEntry.fromJson(
      (body['items'] as List).single.cast<String, Object?>(),
    );
    expect(entry.canRestore, isFalse);
    expect(
      (await call(other.id, 'POST', 'api/trash/${entry.id}/restore')).$1,
      403,
    );
  });

  test('expired substitution rights also end for deleted task snapshots', () {
    final person = app.accounts.create(
      username: 'absent',
      displayName: 'Absent',
    );
    final today = tz.TZDateTime.now(app.location);
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    void absence(DateTime end) => save(
      Collections.absences,
      'absence',
      MemberAbsence(
        id: 'absence',
        memberId: person.id,
        from: yesterday,
        to: end,
        substituteId: other.id,
      ).toData(),
    );
    absence(today);
    save(
      Collections.tasks,
      'task',
      Task(
        id: 'task',
        title: 'Private task',
        assigneeIds: [person.id],
        visibleTo: [owner.id, person.id],
      ).toData(),
    );
    remove(Collections.tasks, 'task');
    final entry = app.records.trashFor(other.id).$1.single;
    absence(yesterday);
    expect(app.records.trashFor(other.id).$1, isEmpty);
    expect(
      () => app.records.restoreTrash(other.id, entry.id),
      throwsA(isA<ApiException>()),
    );
    expect(app.records.trashFor(owner.id).$1, hasLength(1));
  });

  test(
    'pagination advances past inaccessible snapshots without disclosing them',
    () {
      for (var i = 0; i < 102; i++) {
        save(Collections.notes, '$i', {
          'title': '$i',
          if (i > 0) 'visibleTo': [owner.id],
        });
        remove(Collections.notes, '$i');
      }
      final first = app.records.trashFor(other.id);
      expect(first.$1, isEmpty);
      expect(first.$2, isNotNull);
      expect(
        app.records.trashFor(other.id, before: first.$2).$1.single.title,
        '0',
      );
    },
  );
}
