import 'dart:convert';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember owner, member;
  late LocalStore local;
  late SyncEngine engine;
  late FamioApiClient api;
  late FileRef file;
  final sent = <SyncRequest>[];
  void Function()? onBlockedReply;
  setUp(() async {
    sent.clear();
    onBlockedReply = null;
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    member = app.accounts.create(username: 'member', displayName: 'Member');
    final token = app.accounts.createSession(member.id);
    final upload = await app.files.save(
      owner: owner.id,
      name: 'shared.txt',
      mime: 'text/plain',
      body: Stream.value([1]),
    );
    file = FileRef(
      id: upload.id,
      name: upload.name,
      mime: upload.mime,
      size: upload.size,
    );
    api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient((request) async {
        sent.add(
          SyncRequest.fromJson((jsonDecode(request.body) as Map).cast()),
        );
        final result = await app.handler(
          Request(
            request.method,
            request.url,
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            },
            body: request.body,
          ),
        );
        final body = await result.readAsString();
        if ((jsonDecode(body) as Map)['blocked'] case final List issues
            when issues.isNotEmpty) {
          final callback = onBlockedReply;
          onBlockedReply = null;
          callback?.call();
        }
        return http.Response(
          body,
          result.statusCode,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    local = LocalStore.open(':memory:');
    engine = SyncEngine(store: local, api: api, memberId: member.id);
  });
  tearDown(() async {
    await engine.dispose();
    api.close();
    local.close();
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  void share(bool value) => app.records.writeAs(owner.id, [
    SyncRecord(
      collection: Collections.documents,
      id: 'source',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      data: FamilyDocument(
        id: 'source',
        title: 'Source',
        category: DocumentCategory.other,
        file: file,
        visibleTo: value ? null : [owner.id],
      ).toData(),
    ),
  ]);

  Future<void> block() async {
    share(true);
    await engine.sync();
    engine.put(
      Collections.tasks,
      'task',
      Task(id: 'task', title: 'Repair me', photos: [file]).toData(),
    );
    engine.put(Collections.notes, 'independent', {
      'title': 'Valid independent change',
    });
    share(false);
    await engine.sync();
  }

  test(
    'revoked attachments isolate one edit while valid writes and revocations arrive',
    () async {
      await block();
      expect(engine.status.state, SyncState.attention);
      expect(engine.blockedChanges.single.id, 'task');
      expect(app.records.get(Collections.notes, 'independent'), isNotNull);
      expect(local.get(Collections.documents, 'source'), isNull);
      expect(local.get(Collections.tasks, 'task')!.dirty, isTrue);
      expect(app.records.get(Collections.tasks, 'task'), isNull);
      final before = sent.length;
      await engine.sync();
      expect(sent.length, before + 1);
      expect(
        sent.last.changes,
        isEmpty,
        reason: 'unchanged repair candidates do not spin',
      );
      engine.put(
        Collections.tasks,
        'task',
        Task(id: 'task', title: 'Repaired').toData(),
      );
      await engine.sync();
      expect(engine.status.state, SyncState.idle);
      expect(engine.blockedChanges, isEmpty);
      expect(
        app.records.get(Collections.tasks, 'task')!.data['title'],
        'Repaired',
      );
    },
  );

  test(
    'blocked edits survive a restart and explicit retry after re-sharing succeeds',
    () async {
      await block();
      await engine.dispose();
      engine = SyncEngine(store: local, api: api, memberId: member.id);
      await engine.sync();
      expect(sent.last.changes, isEmpty);
      expect(engine.blockedChanges.single.id, 'task');
      share(true);
      await engine.retryBlockedChanges();
      expect(engine.status.state, SyncState.idle);
      expect(app.records.get(Collections.tasks, 'task'), isNotNull);
      expect(local.dirty, isEmpty);
    },
  );

  test(
    'other server edits do not erase a blocked local repair candidate',
    () async {
      share(true);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          data: {'title': 'Original'},
          updatedAt: 1,
        ),
      ]);
      await engine.sync();
      engine.put(
        Collections.tasks,
        'task',
        Task(id: 'task', title: 'Keep my changes', photos: [file]).toData(),
      );
      share(false);
      await engine.sync();
      final pending = local.get(Collections.tasks, 'task')!.record;
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          data: {'title': 'Other server edit'},
          updatedAt: pending.updatedAt + 1,
        ),
      ]);
      await engine.sync();
      expect(
        engine.record(Collections.tasks, 'task')!.data['title'],
        'Keep my changes',
      );
      expect(engine.blockedChanges, hasLength(1));
      expect(local.get(Collections.tasks, 'task')!.dirty, isTrue);
    },
  );

  test(
    'a repair made while its old error response is in flight is not blocked',
    () async {
      onBlockedReply = () => engine.put(
        Collections.tasks,
        'task',
        Task(id: 'task', title: 'Repaired in flight').toData(),
      );
      await block();
      expect(engine.status.state, SyncState.idle);
      expect(engine.blockedChanges, isEmpty);
      expect(
        app.records.get(Collections.tasks, 'task')!.data['title'],
        'Repaired in flight',
      );
      expect(local.dirty, isEmpty);
    },
  );

  test(
    'a changed access scope does not overwrite a still permitted blocked edit',
    () async {
      share(true);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          data: {'title': 'Original'},
          updatedAt: 1,
        ),
      ]);
      await engine.sync();
      engine.put(
        Collections.tasks,
        'task',
        Task(id: 'task', title: 'Keep this repair', photos: [file]).toData(),
      );
      share(false);
      await engine.sync();
      final pending = local.get(Collections.tasks, 'task')!.record;
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          data: {'title': 'Newer server edit'},
          updatedAt: pending.updatedAt + 1,
        ),
      ]);
      app.accounts.update(member.id, role: MemberRole.child);
      await engine.sync();
      expect(engine.status.state, SyncState.attention);
      expect(engine.blockedChanges.single.data['title'], 'Keep this repair');
      expect(local.get(Collections.tasks, 'task')!.dirty, isTrue);
      final before = sent.length;
      await engine.sync();
      expect(sent.length, before + 1);
      expect(sent.last.changes, isEmpty);
    },
  );

  test(
    'a role downgrade revalidates and removes a now forbidden blocked document',
    () async {
      share(true);
      await engine.sync();
      engine.put(
        Collections.documents,
        'pending-document',
        FamilyDocument(
          id: 'pending-document',
          title: 'Pending',
          category: DocumentCategory.other,
          file: file,
        ).toData(),
      );
      share(false);
      await engine.sync();
      expect(engine.blockedChanges.single.id, 'pending-document');
      app.accounts.update(member.id, role: MemberRole.guest);
      await engine.sync();
      expect(local.get(Collections.documents, 'pending-document'), isNull);
      expect(engine.blockedChanges, isEmpty);
      expect(engine.status.state, SyncState.idle);
    },
  );

  test('revoking a task still removes its blocked local edit', () async {
    share(true);
    app.records.writeAs(owner.id, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'task',
        data: {'title': 'Original'},
        updatedAt: 1,
      ),
    ]);
    await engine.sync();
    engine.put(
      Collections.tasks,
      'task',
      Task(id: 'task', title: 'Pending', photos: [file]).toData(),
    );
    share(false);
    await engine.sync();
    expect(engine.blockedChanges, hasLength(1));
    app.records.writeAs(owner.id, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'task',
        data: Task(
          id: 'task',
          title: 'Private now',
          visibleTo: [owner.id],
        ).toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch + 1,
      ),
    ]);
    await engine.sync();
    expect(local.get(Collections.tasks, 'task'), isNull);
    expect(engine.blockedChanges, isEmpty);
    expect(engine.status.state, SyncState.idle);
  });
}
