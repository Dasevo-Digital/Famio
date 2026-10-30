import 'dart:convert';
import 'dart:io';
import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember owner, other;
  late FileRef file;
  setUp(() async {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    other = app.accounts.create(username: 'other', displayName: 'Other');
    final saved = await app.files.save(
      owner: owner.id,
      name: 'fixture.bin',
      mime: 'application/octet-stream',
      body: Stream.value([1, 2, 3, 4]),
    );
    file = FileRef(
      id: saved.id,
      name: saved.name,
      mime: saved.mime,
      size: saved.size,
    );
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });
  Map<String, Object?> data(String title) => {
    'title': title,
    'file': {
      ...file.toJson(),
      'size': 1,
      'name': 'old-name',
      'mime': 'text/plain',
      'future': true,
    },
  };
  test(
    'sync stores canonical attachment metadata and preserves unknown fields',
    () {
      final input = data('Fixture');
      app.records.sync(
        SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.documents,
              id: 'document',
              updatedAt: 1,
              data: input,
            ),
          ],
        ),
        owner.id,
      );
      final response = app.records.sync(
        SyncRequest(since: 0, changes: []),
        other.id,
      );
      final record = response.changes.singleWhere(
        (r) => r.collection == Collections.documents,
      );
      expect(record.data['file'], {...file.toJson(), 'future': true});
      expect((input['file'] as Map)['size'], 1);
      expect(
        app.records.get(Collections.documents, 'document')!.data['file'],
        record.data['file'],
      );
    },
  );
  test('a losing edit has canonical metadata in its retained conflict', () {
    app.records.writeAs(owner.id, [
      SyncRecord(
        collection: Collections.documents,
        id: 'document',
        updatedAt: 200,
        data: data('Kept'),
      ),
    ]);
    app.records.writeAs(other.id, [
      SyncRecord(
        collection: Collections.documents,
        id: 'document',
        updatedAt: 100,
        data: data('Lost'),
      ),
    ]);
    final conflict = app.records.all(Collections.conflicts).single;
    expect((conflict.data['lost'] as Map)['file'], {
      ...file.toJson(),
      'future': true,
    });
  });
  test(
    'metadata normalization does not grant access to a foreign unattached file',
    () async {
      final secret = await app.files.save(
        owner: other.id,
        name: 'private.bin',
        mime: 'text/plain',
        body: Stream.value([7]),
      );
      expect(
        () => app.records.sync(
          SyncRequest(
            since: 0,
            changes: [
              SyncRecord(
                collection: Collections.documents,
                id: 'forbidden',
                updatedAt: 1,
                data: {'title': 'Foreign', 'file': secret.toJson()},
              ),
            ],
          ),
          owner.id,
        ),
        throwsA(predicate((e) => '$e'.contains('invalid_file_reference'))),
      );
      expect(app.records.get(Collections.documents, 'forbidden'), isNull);
    },
  );
  test(
    'legacy live records and trash are repaired with revisions and unchanged audiences',
    () {
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.documents,
          id: 'live',
          updatedAt: 10,
          data: {
            ...data('Live'),
            SyncRecord.visibilityKey: [owner.id],
          },
        ),
        SyncRecord(
          collection: Collections.documents,
          id: 'trashed',
          updatedAt: 11,
          data: data('Trash'),
        ),
      ]);
      final removed = app.records.get(Collections.documents, 'trashed')!;
      app.records.writeAs(owner.id, [
        removed.copyWith(deleted: true, updatedAt: 12),
      ]);
      app.db.execute(
        'UPDATE records SET data = ? WHERE collection = ? AND id = ?',
        [
          jsonEncode({
            ...data('Live'),
            SyncRecord.visibilityKey: [owner.id],
          }),
          Collections.documents,
          'live',
        ],
      );
      final trash = app.db.select('SELECT id,snapshot FROM trash').single;
      final snapshot = SyncRecord.fromJson(
        (jsonDecode(trash['snapshot'] as String) as Map).cast(),
      );
      app.db.execute('UPDATE trash SET snapshot = ? WHERE id = ?', [
        jsonEncode(snapshot.copyWith(data: data('Trash')).toJson()),
        trash['id'],
      ]);
      app.db.execute('DELETE FROM settings WHERE key = ?', [
        'canonicalFileMetadata1',
      ]);
      final before = app.records.get(Collections.documents, 'live')!;
      final revision = app.records.currentRev;
      expect(app.records.repairFileMetadata(), 2);
      final after = app.records.get(Collections.documents, 'live')!;
      expect(after.updatedAt, before.updatedAt);
      expect(after.updatedBy, before.updatedBy);
      expect(after.visibleTo, [owner.id]);
      expect(after.rev, greaterThan(revision));
      expect(after.data['file'], {...file.toJson(), 'future': true});
      expect(app.records.trashFor(owner.id).$1.single.record.data['file'], {
        ...file.toJson(),
        'future': true,
      });
      expect(
        app.records
            .sync(SyncRequest(since: revision, changes: []), owner.id)
            .changes
            .any((r) => r.id == 'live'),
        isTrue,
      );
      expect(
        app.records
            .sync(SyncRequest(since: revision, changes: []), other.id)
            .changes
            .any((r) => r.id == 'live'),
        isFalse,
      );
      final repairedRev = app.records.currentRev;
      expect(app.records.repairFileMetadata(), 0);
      expect(app.records.currentRev, repairedRev);
    },
  );
  test(
    'legacy conflict snapshots are repaired without exposing them to another member',
    () {
      final raw = {
        'collection': Collections.documents,
        'recordId': 'old-document',
        'lost': data('Lost'),
        SyncRecord.visibilityKey: [owner.id],
        'future': true,
      };
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.conflicts,
          id: 'old-conflict',
          updatedAt: 1,
          data: raw,
        ),
      ]);
      app.db.execute('UPDATE records SET data = ? WHERE collection = ?', [
        jsonEncode(raw),
        Collections.conflicts,
      ]);
      app.db.execute('DELETE FROM settings WHERE key = ?', [
        'canonicalFileMetadata1',
      ]);
      expect(app.records.repairFileMetadata(), 1);
      final restored = app.records.get(Collections.conflicts, 'old-conflict')!;
      expect((restored.data['lost'] as Map)['file'], {
        ...file.toJson(),
        'future': true,
      });
      expect(restored.data['future'], isTrue);
      expect(restored.visibleTo, [owner.id]);
      expect(app.records.canAccess(restored, other.id), isFalse);
    },
  );
  test(
    'legacy repair leaves malformed rows intact and repairs readable attachments',
    () {
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.documents,
          id: 'readable',
          updatedAt: 1,
          data: data('Readable'),
        ),
        SyncRecord(
          collection: Collections.notes,
          id: 'damaged',
          updatedAt: 1,
          data: {'title': 'Fixture', 'text': ''},
        ),
      ]);
      app.db.execute(
        'UPDATE records SET data = ? WHERE collection = ? AND id = ?',
        [jsonEncode(data('Readable')), Collections.documents, 'readable'],
      );
      app.db.execute('UPDATE records SET data = ? WHERE collection = ?', [
        '{broken',
        Collections.notes,
      ]);
      app.db.execute(
        'INSERT INTO trash (id,collection,record_id,snapshot,deleted_rev,deleted_at,expires_at) VALUES (?,?,?,?,?,?,?)',
        [
          'damaged-trash',
          Collections.notes,
          'damaged',
          '{broken',
          1,
          0,
          8640000000000000,
        ],
      );
      app.db.execute('DELETE FROM settings WHERE key = ?', [
        'canonicalFileMetadata1',
      ]);
      expect(app.records.repairFileMetadata(), 1);
      expect(
        FamilyDocument.fromRecord(
          app.records.get(Collections.documents, 'readable')!,
        ).file!.size,
        4,
      );
      expect(
        app.db.select('SELECT data FROM records WHERE id = ?', [
          'damaged',
        ]).single['data'],
        '{broken',
      );
      expect(
        app.db.select('SELECT snapshot FROM trash WHERE id = ?', [
          'damaged-trash',
        ]).single['snapshot'],
        '{broken',
      );
    },
  );
  test('legacy repair remains bounded across multiple replacement batches', () {
    app.records.writeAsServer([
      for (var i = 0; i < 135; i++)
        SyncRecord(
          collection: Collections.documents,
          id: 'document$i',
          updatedAt: 1,
          data: data('Fixture'),
        ),
    ]);
    app.db.execute(
      "UPDATE records SET data = json_set(data, '\$.file.size', 1) WHERE collection = ?",
      [Collections.documents],
    );
    app.db.execute('DELETE FROM settings WHERE key = ?', [
      'canonicalFileMetadata1',
    ]);
    expect(app.records.repairFileMetadata(), 135);
    expect(app.records.all(Collections.documents), hasLength(135));
    expect(
      app.records
          .all(Collections.documents)
          .map((r) => FamilyDocument.fromRecord(r).file!.size),
      everyElement(4),
    );
  });
  test('the repair keeps answers given to a task whose photo it corrects', () {
    final task = Task(
      id: 'task',
      title: 'Fixture',
      assigneeIds: [other.id],
      due: DateTime(2030, 1, 1),
      photos: [file],
      assignmentConfirmation: const AssignmentSettings(required: true),
    );
    app.records.writeAs(owner.id, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'task',
        updatedAt: 10,
        data: task.toData(),
      ),
    ]);
    // A task stored before the server kept attachment metadata canonical.
    app.db.execute(
      'UPDATE records SET data = ? WHERE collection = ? AND id = ?',
      [
        jsonEncode({
          ...task.toData(),
          'photos': [
            {...file.toJson(), 'size': 1, 'name': 'old-name'},
          ],
        }),
        Collections.tasks,
        'task',
      ],
    );
    final legacy = app.records.assignmentRequestsFor(
      app.records.get(Collections.tasks, 'task')!,
    );
    expect(legacy, hasLength(1));
    final request = legacy.single;
    expect(
      app.records.writeAs(other.id, [
        SyncRecord(
          collection: Collections.assignmentResponses,
          id: request.id,
          updatedAt: 20,
          data: AssignmentResponse(
            targetCollection: Collections.tasks,
            targetId: 'task',
            memberId: other.id,
            kind: request.kind,
            fingerprint: request.fingerprint,
            decision: AssignmentDecision.accepted,
          ).toData(),
        ),
      ]),
      isEmpty,
    );
    app.db.execute('DELETE FROM settings WHERE key = ?', [
      'canonicalFileMetadata1',
    ]);
    final revision = app.records.currentRev;
    expect(app.records.repairFileMetadata(), 1);
    final repaired = app.records.get(Collections.tasks, 'task')!;
    expect(repaired.data['photos'], [file.toJson()]);
    final current = app.records.assignmentRequestsFor(repaired).single;
    expect(current.fingerprint, isNot(request.fingerprint));
    final answer = app.records.get(
      Collections.assignmentResponses,
      request.id,
    )!;
    expect(answer.deleted, isFalse);
    expect(answer.updatedAt, 20);
    expect(answer.data['decision'], 'accepted');
    expect(answer.data['fingerprint'], current.fingerprint);
    // The assignee's device receives the moved answer with the task.
    final changes = app.records
        .sync(SyncRequest(since: revision, changes: []), other.id)
        .changes;
    expect(changes.map((r) => r.id), containsAll(['task', request.id]));
  });
}
