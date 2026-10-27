import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/backup/backup_check.dart';
import 'package:famio_server/src/api_exception.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember owner;
  late String ownerToken;

  Future<(int, Map)> call(
    String method,
    String path, {
    String? token,
    Object? body,
  }) async {
    final response = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/').resolve(path),
        headers: {
          'authorization': ?(token == null ? null : 'Bearer $token'),
          'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await response.readAsString();
    return (response.statusCode, text.isEmpty ? {} : jsonDecode(text) as Map);
  }

  setUp(() {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(
      username: 'owner',
      displayName: 'Owner',
      isAdmin: true,
    );
    ownerToken = app.accounts.createSession(owner.id);
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  test(
    'known file ids in text or forged attachments do not grant access',
    () async {
      final guest = app.accounts.create(
        username: 'guest',
        displayName: 'Guest',
        role: MemberRole.guest,
      );
      final token = app.accounts.createSession(guest.id);
      final file = await app.files.save(
        owner: owner.id,
        name: 'private.txt',
        mime: 'text/plain',
        body: Stream.value(utf8.encode('private fixture')),
      );
      final ref = FileRef(
        id: file.id,
        name: file.name,
        mime: file.mime,
        size: file.size,
      );
      Future<int> download() async => (await app.handler(
        Request(
          'GET',
          Uri.parse('http://famio.test/api/files/${file.id}'),
          headers: {'authorization': 'Bearer $token'},
        ),
      )).statusCode;
      expect(await download(), 404);
      final text = await call(
        'POST',
        'api/sync',
        token: token,
        body: SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.tasks,
              id: 'text',
              data: Task(
                id: 'text',
                title: 'Task',
                notes: file.id,
                assigneeIds: [guest.id],
              ).toData(),
              updatedAt: 1,
            ),
          ],
        ).toJson(),
      );
      expect(text.$1, 200);
      expect(await download(), 404);
      final forged = await call(
        'POST',
        'api/sync',
        token: token,
        body: SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.tasks,
              id: 'batch-first',
              data: {
                'title': 'Must roll back',
                'assigneeIds': [guest.id],
              },
              updatedAt: 2,
            ),
            SyncRecord(
              collection: Collections.tasks,
              id: 'forged',
              data: Task(
                id: 'forged',
                title: 'Task',
                photos: [ref],
                assigneeIds: [guest.id],
              ).toData(),
              updatedAt: 2,
            ),
          ],
        ).toJson(),
      );
      expect(forged.$1, 400);
      expect(app.records.get(Collections.tasks, 'forged'), isNull);
      expect(app.records.get(Collections.tasks, 'batch-first'), isNull);
      expect(await download(), 404);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.chatMessages,
          id: 'shared',
          data: ChatMessage(
            id: 'shared',
            chatId: 'family',
            authorId: owner.id,
            text: '',
            sentAt: DateTime.now(),
            attachment: ref,
          ).toData(),
          updatedAt: 3,
        ),
      ]);
      expect(await download(), 200, reason: 'genuine sharing still works');
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.chatMessages,
          id: 'shared',
          data: ChatMessage(
            id: 'shared',
            chatId: 'family',
            authorId: owner.id,
            sentAt: DateTime.now(),
            attachment: ref,
            visibleTo: [owner.id],
          ).toData(),
          updatedAt: 4,
        ),
      ]);
      expect(
        await download(),
        404,
        reason: 'revoking the real reference withdraws access',
      );
    },
  );

  test(
    'editing an existing record does not reattach its missing upload',
    () async {
      final file = await app.files.save(
        owner: owner.id,
        name: 'old.txt',
        mime: 'text/plain',
        body: Stream.value([1]),
      );
      final task = Task(
        id: 'old',
        title: 'Task',
        photos: [
          FileRef(
            id: file.id,
            name: file.name,
            mime: file.mime,
            size: file.size,
          ),
        ],
      );
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: task.id,
          data: task.toData(),
          updatedAt: 1,
        ),
      ]);
      // A partial restore lost the upload, but the existing task is still usable.
      app.db.execute('DELETE FROM files WHERE id = ?', [file.id]);
      expect(
        app.records.writeAs(owner.id, [
          SyncRecord(
            collection: Collections.tasks,
            id: task.id,
            data: task.copyWith(done: true).toData(),
            updatedAt: 2,
          ),
        ]),
        isEmpty,
      );
      expect(
        Task.fromRecord(app.records.get(Collections.tasks, task.id)!).done,
        isTrue,
      );
    },
  );

  test(
    'malformed records are rejected atomically without persisting poison',
    () async {
      final child = app.accounts.create(
        username: 'child',
        displayName: 'Child',
        role: MemberRole.child,
      );
      final token = app.accounts.createSession(child.id);
      for (final data in [
        {'title': 42},
        {'title': 'Note', 'pinned': 'yes'},
        {
          'title': 'Note',
          'visibleTo': [42],
        },
      ]) {
        final result = await call(
          'POST',
          'api/sync',
          token: token,
          body: SyncRequest(
            since: 0,
            changes: [
              SyncRecord(
                collection: Collections.notes,
                id: 'valid',
                data: {'title': 'Good'},
                updatedAt: 1,
              ),
              SyncRecord(
                collection: Collections.notes,
                id: 'bad',
                data: data,
                updatedAt: 2,
              ),
            ],
          ).toJson(),
        );
        expect(result.$1, 400);
        expect(app.records.all(Collections.notes), isEmpty);
      }
    },
  );

  test('all-session revocation invalidates an outstanding pairing', () async {
    final member = app.accounts.create(
      username: 'member',
      displayName: 'Member',
    );
    final source = app.accounts.createSession(member.id, method: 'totp');
    final (_, pairing) = await call(
      'POST',
      'api/me/device-pairings',
      token: source,
    );
    expect(
      (await call(
        'DELETE',
        'api/admin/users/${member.id}/sessions',
        token: ownerToken,
      )).$1,
      200,
    );
    expect((await call('GET', 'api/me', token: source)).$1, 401);
    expect(
      (await call(
        'POST',
        'api/auth/device-pair',
        body: {'secret': pairing['secret']},
      )).$1,
      401,
    );
  });

  test(
    'password changes invalidate pairing even if the approving session remains',
    () async {
      final (_, pairing) = await call(
        'POST',
        'api/me/device-pairings',
        token: ownerToken,
      );
      await app.accounts.setPassword(owner.id, 'tulpe-regal-7');
      expect(app.accounts.userForToken(ownerToken), isNotNull);
      expect(
        (await call(
          'POST',
          'api/auth/device-pair',
          body: {'secret': pairing['secret']},
        )).$1,
        401,
      );
    },
  );

  test(
    'simultaneous uploads share the quota and release failed reservations',
    () async {
      final blobs = sqlite3.openInMemory();
      addTearDown(blobs.close);
      final files = FileStore(
        app.db,
        blobs: blobs,
        dataDir: app.dataDir,
        records: app.records,
        maxBytes: () => 100,
        maxTotalBytes: () => 100,
      );
      final a = StreamController<List<int>>(),
          b = StreamController<List<int>>();
      var failures = 0;
      Future<StoredFile?> save(Stream<List<int>> stream) => files
          .save(
            owner: owner.id,
            name: 'fixture',
            mime: 'text/plain',
            body: stream,
          )
          .then<StoredFile?>(
            (f) => f,
            onError: (Object e) {
              expect(e, isA<ApiException>());
              failures++;
              return null;
            },
          );
      final results = Future.wait([save(a.stream), save(b.stream)]);
      a.add(List.filled(60, 1));
      b.add(List.filled(20, 2));
      b.add(List.filled(40, 2));
      await Future.wait([a.close(), b.close()]);
      expect((await results).whereType<StoredFile>(), hasLength(1));
      expect(failures, 1);
      expect(files.usage().$2, 60);
      await save(Stream.value(List.filled(40, 3)));
      expect(files.usage().$2, 100);
      expect(blobs.select('SELECT DISTINCT id FROM blobs'), hasLength(2));
    },
  );

  for (final gap in [false, true]) {
    test(
      'backup detects ${gap ? 'missing sequence positions' : 'truncated file contents'}',
      () async {
        final file = await app.files.save(
          owner: owner.id,
          name: 'blocks',
          mime: 'text/plain',
          body: Stream.fromIterable([
            List.filled(1024 * 1024, 1),
            List.filled(16, 2),
          ]),
        );
        final backup = await app.backups!.run();
        final folder = app.backups!.folder(backup.name)!;
        final db = sqlite3.open('${folder.path}/files.db');
        if (gap) {
          db.execute('UPDATE blobs SET seq = 2 WHERE id = ? AND seq = 1', [
            file.id,
          ]);
        } else {
          db.execute('DELETE FROM blobs WHERE id = ? AND seq = 1', [file.id]);
        }
        db.close();
        final result = checkBackup(
          folder.path,
          hexKey: null,
          liveUsers: 1,
          liveRecords: 0,
        );
        expect(result.filesChecked, isTrue);
        expect(result.ok, isFalse);
        expect(result.problems.join(), contains('Unvollständige Dateiinhalte'));
      },
    );
  }
}
