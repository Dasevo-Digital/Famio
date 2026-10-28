import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember owner, child;
  late String token;
  late FileRef file;
  setUp(() async {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    child = app.accounts.create(
      username: 'child',
      displayName: 'Child',
      role: MemberRole.child,
    );
    token = app.accounts.createSession(child.id);
    final stored = await app.files.save(
      owner: owner.id,
      name: 'private.txt',
      mime: 'text/plain',
      body: Stream.value(utf8.encode('private fixture')),
    );
    file = FileRef(
      id: stored.id,
      name: stored.name,
      mime: stored.mime,
      size: stored.size,
    );
    app.records.writeAs(owner.id, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'shared',
        data: Task(id: 'shared', title: 'Shared').toData(),
        updatedAt: 100,
      ),
    ]);
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<int> download() async {
    final response = await app.handler(
      Request(
        'GET',
        Uri.parse('http://famio.test/api/files/${file.id}'),
        headers: {'authorization': 'Bearer $token'},
      ),
    );
    await response.readAsString();
    return response.statusCode;
  }

  for (final deferred in [false, true]) {
    test(
      'a losing edit never authorizes a foreign file (deferred=$deferred)',
      () async {
        expect(await download(), 404);
        final response = await app.handler(
          Request(
            'POST',
            Uri.parse('http://famio.test/api/sync'),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            },
            body: jsonEncode(
              SyncRequest(
                since: 0,
                deferInvalidFiles: deferred,
                changes: [
                  SyncRecord(
                    collection: Collections.notes,
                    id: 'valid',
                    data: {'title': 'Valid'},
                    updatedAt: 1,
                  ),
                  SyncRecord(
                    collection: Collections.tasks,
                    id: 'shared',
                    data: Task(
                      id: 'shared',
                      title: 'Losing',
                      photos: [file],
                    ).toData(),
                    updatedAt: 99,
                  ),
                ],
              ).toJson(),
            ),
          ),
        );
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(response.statusCode, deferred ? 200 : 400);
        expect(await download(), 404);
        expect(app.records.all(Collections.conflicts), isEmpty);
        expect(
          app.records.get(Collections.tasks, 'shared')!.data['title'],
          'Shared',
        );
        expect(app.records.get(Collections.notes, 'valid') != null, deferred);
        if (deferred) {
          final result = SyncResponse.fromJson(body.cast());
          expect(result.blocked.single.id, 'shared');
          expect(result.blocked.single.updatedAt, 99);
          expect(result.blocked.single.code, 'invalid_file_reference');
        }
      },
    );
  }

  test(
    'an authorized losing attachment remains available through its conflict',
    () async {
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.documents,
          id: 'source',
          data: FamilyDocument(
            id: 'source',
            title: 'Shared',
            category: DocumentCategory.other,
            file: file,
          ).toData(),
          updatedAt: 101,
        ),
      ]);
      expect(await download(), 200);
      final result = app.records.sync(
        SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.tasks,
              id: 'shared',
              data: Task(
                id: 'shared',
                title: 'Losing',
                photos: [file],
              ).toData(),
              updatedAt: 99,
            ),
          ],
        ),
        child.id,
      );
      expect(result.rejected.single.id, 'shared');
      expect(
        app.records.all(Collections.conflicts, visibleToMember: child.id),
        hasLength(1),
      );
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.documents,
          id: 'source',
          data: FamilyDocument(
            id: 'source',
            title: 'Private',
            category: DocumentCategory.other,
            file: file,
            visibleTo: [owner.id],
          ).toData(),
          updatedAt: 102,
        ),
      ]);
      expect(await download(), 200);
    },
  );

  test(
    'quarantined records retain real uploads without granting read access',
    () async {
      final orphan = await app.files.save(
        owner: owner.id,
        name: 'orphan.txt',
        mime: 'text/plain',
        body: Stream.value([1]),
      );
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.documents,
          id: 'damaged',
          data: {'title': 42, 'file': file.toJson()},
          updatedAt: 1,
        ),
      ]);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.notes,
          id: 'mention',
          data: {'title': 'Text only', 'text': orphan.id},
          updatedAt: 2,
        ),
      ]);
      app.db.execute('UPDATE files SET created_at = ?', [
        DateTime.now()
            .subtract(const Duration(hours: 25))
            .millisecondsSinceEpoch,
      ]);
      expect(app.records.referenced(file.id), isTrue);
      expect(await download(), 404);
      expect(app.files.collectGarbage(), 1);
      expect(app.files.get(file.id), isNotNull);
      expect(app.files.get(orphan.id), isNull);
      expect(app.records.get(Collections.documents, 'damaged'), isNotNull);
    },
  );
}
