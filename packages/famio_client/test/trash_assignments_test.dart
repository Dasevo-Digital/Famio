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
  final engines = <SyncEngine>[];
  var offline = false;
  SyncEngine client(String id) {
    final token = app.accounts.createSession(id);
    final api = FamioApiClient(
      'http://localhost',
      token: token,
      httpClient: MockClient((r) async {
        if (offline) throw http.ClientException('Offline fixture');
        final result = await app.handler(
          Request(r.method, r.url, headers: r.headers, body: r.body),
        );
        return http.Response(
          await result.readAsString(),
          result.statusCode,
          headers: result.headers,
        );
      }),
    );
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: api,
      memberId: id,
    );
    engines.add(engine);
    return engine;
  }

  setUp(() {
    offline = false;
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    member = app.accounts.create(username: 'member', displayName: 'Member');
  });

  test(
    'offline edits made before deletion are preserved when the server base is unchanged',
    () async {
      final first = client(owner.id);
      first.put(Collections.notes, 'note', {'title': 'Synced title'});
      await first.sync();
      first.put(Collections.notes, 'note', {'title': 'Latest offline edit'});
      first.delete(Collections.notes, 'note');
      await first.sync();
      final second = client(owner.id);
      final entry = (await second.api.trash()).items.single;
      expect(entry.title, 'Latest offline edit');
      await second.api.restoreTrash(entry.id);
      await first.sync();
      expect(
        first.record(Collections.notes, 'note')!.data['title'],
        'Latest offline edit',
      );
    },
  );
  tearDown(() async {
    for (final engine in engines) {
      await engine.dispose();
      engine.store.close();
      engine.api.close();
    }
    engines.clear();
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  test(
    'a deletion made entirely offline is available on another device after sync',
    () async {
      final first = client(owner.id);
      first.put(Collections.notes, 'note', {'title': 'Never uploaded yet'});
      first.delete(Collections.notes, 'note');
      await first.sync();
      final second = client(owner.id);
      final trash = await second.api.trash();
      expect(trash.items.single.title, 'Never uploaded yet');
      await second.api.restoreTrash(trash.items.single.id);
      await second.sync();
      await first.sync();
      expect(
        second.record(Collections.notes, 'note')!.data['title'],
        'Never uploaded yet',
      );
      expect(
        first.record(Collections.notes, 'note')!.data['title'],
        'Never uploaded yet',
      );
      expect((await first.api.trash()).items, isEmpty);
    },
  );

  test(
    'a queued offline response survives restarting and reaches the other device',
    () async {
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          updatedAt: 1,
          data: Task(
            id: 'task',
            title: 'Help',
            assigneeIds: [member.id],
            assignmentConfirmation: const AssignmentSettings(required: true),
          ).toData(),
        ),
      ]);
      final assigned = client(member.id);
      final observer = client(owner.id);
      await assigned.sync();
      final request = assignmentRequests(
        assigned.record(Collections.tasks, 'task')!,
      ).single;
      offline = true;
      assigned.respondToAssignment(request, AssignmentDecision.accepted);
      await assigned.sync();
      expect(assigned.status.state, SyncState.offline);
      await assigned.dispose();
      final restarted = SyncEngine(
        store: assigned.store,
        api: assigned.api,
        memberId: member.id,
      );
      engines.remove(assigned);
      engines.add(restarted);
      expect(
        restarted.assignmentDecision(request),
        AssignmentDecision.accepted,
      );
      offline = false;
      await restarted.sync();
      await observer.sync();
      expect(observer.assignmentDecision(request), AssignmentDecision.accepted);
      final old = app.records.get(Collections.tasks, 'task')!;
      app.records.writeAs(owner.id, [
        old.copyWith(
          updatedAt: old.updatedAt + 1,
          data: {...old.data, 'title': 'Changed assignment'},
        ),
      ]);
      await restarted.sync();
      final changed = assignmentRequests(
        restarted.record(Collections.tasks, 'task')!,
      ).single;
      expect(restarted.assignmentDecision(changed), isNull);
      expect(restarted.store.dirty, isEmpty);
    },
  );

  test(
    'synchronized trash snapshots never appear as ordinary family records',
    () async {
      final first = client(owner.id);
      first.put(Collections.notes, 'note', {
        'title': 'Deleted private',
        'visibleTo': [owner.id],
      });
      await first.sync();
      first.delete(Collections.notes, 'note');
      await first.sync();
      final other = client(member.id);
      await other.sync();
      expect(other.record(Collections.notes, 'note'), isNull);
      expect((await other.api.trash()).items, isEmpty);
      expect(other.store.get(Collections.notes, 'note'), isNull);
    },
  );

  test(
    'deleting a family task removes copies from every assigned guest device',
    () async {
      app.accounts.update(member.id, role: MemberRole.guest);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          updatedAt: 1,
          data: Task(
            id: 'task',
            title: 'For guest',
            assigneeIds: [member.id],
          ).toData(),
        ),
      ]);
      final guest = client(member.id);
      await guest.sync();
      expect(guest.record(Collections.tasks, 'task'), isNotNull);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 'task',
          data: const {},
          updatedAt: 2,
          deleted: true,
        ),
      ]);
      await guest.sync();
      expect(guest.record(Collections.tasks, 'task'), isNull);
      expect((await guest.api.trash()).items.single.title, 'For guest');
    },
  );
}
