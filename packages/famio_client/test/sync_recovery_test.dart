import 'dart:convert';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late RecordStore records;
  late FamilyMember member;
  late LocalStore local;
  late SyncEngine engine;
  var failPage = false;
  var requests = 0;

  setUp(() {
    app = FamioServerApp.inMemory();
    records = app.records;
    member = app.accounts.create(username: 'member', displayName: 'Member');
    local = LocalStore.open(':memory:');
    failPage = false;
    requests = 0;
    engine = SyncEngine(
      store: local,
      memberId: member.id,
      api: FamioApiClient(
        'http://localhost',
        httpClient: MockClient((request) async {
          requests++;
          if (failPage && requests == 2) {
            return http.Response(
              '{"error":"temporary","message":"Unavailable"}',
              503,
            );
          }
          final response = records.sync(
            SyncRequest.fromJson((jsonDecode(request.body) as Map).cast()),
            member.id,
          );
          return http.Response(
            jsonEncode(response.toJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
  });
  tearDown(() async {
    await engine.dispose();
    engine.api.close();
    local.close();
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  void note(String id) => records.writeAs(member.id, [
    SyncRecord(
      collection: Collections.notes,
      id: id,
      data: {'title': id},
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  ]);

  test(
    'revision rewind removes records absent from a restored backup',
    () async {
      note('saved');
      note('after-backup');
      await engine.sync();
      app.db.execute('DELETE FROM records WHERE id = ?', ['after-backup']);
      await engine.sync();
      expect(engine.records(Collections.notes).map((r) => r.id), ['saved']);
    },
  );

  test(
    'new server generation reconciles even after revisions caught up',
    () async {
      note('saved');
      note('after-backup');
      await engine.sync();
      app.db.execute('DELETE FROM records WHERE id = ?', ['after-backup']);
      records = RecordStore(
        app.db,
        memberIds: () => [member.id],
        roleOf: (id) => app.accounts.byId(id)!.role,
      );
      note('after-restore');
      expect(records.currentRev, engine.lastRev);
      await engine.sync();
      expect(engine.records(Collections.notes).map((r) => r.id).toSet(), {
        'saved',
        'after-restore',
      });
    },
  );

  test('downgrading an adult removes now forbidden cached documents', () async {
    records.writeAs(member.id, [
      SyncRecord(
        collection: Collections.documents,
        id: 'document',
        data: {'title': 'Private'},
        updatedAt: 1,
      ),
    ]);
    await engine.sync();
    expect(engine.record(Collections.documents, 'document'), isNotNull);
    app.accounts.update(member.id, role: MemberRole.guest);
    await engine.sync();
    expect(local.get(Collections.documents, 'document'), isNull);
  });

  test(
    'upgrading an existing client reconciles a cache without a scope',
    () async {
      note('saved');
      local.put(
        SyncRecord(
          collection: Collections.notes,
          id: 'stale',
          data: {'title': 'Old'},
          updatedAt: 1,
        ),
        dirty: false,
      );
      local.setMeta('lastRev', '${records.currentRev}');
      await engine.sync();
      expect(local.get(Collections.notes, 'stale'), isNull);
      expect(engine.records(Collections.notes).map((r) => r.id), ['saved']);
    },
  );

  test(
    'interrupted paginated reconciliation resumes and removes stale records',
    () async {
      note('stale');
      await engine.sync();
      records = RecordStore(app.db, memberIds: () => [member.id]);
      app.db.execute('DELETE FROM records');
      records.writeAs(member.id, [
        for (var i = 0; i < 501; i++)
          SyncRecord(
            collection: Collections.notes,
            id: 'n$i',
            data: {'title': 'Note'},
            updatedAt: 1,
          ),
      ]);
      requests = 0;
      failPage = true;
      await engine.sync();
      expect(engine.status.state, SyncState.offline);
      expect(local.getMeta('syncReset'), '1');
      failPage = false;
      await engine.sync();
      expect(engine.status.state, SyncState.idle);
      expect(local.get(Collections.notes, 'stale'), isNull);
      expect(engine.records(Collections.notes), hasLength(501));
      expect(local.getMeta('syncReset'), '0');
    },
  );

  test(
    'damaged local records stay recoverable without breaking views or sync',
    () async {
      local.put(
        SyncRecord(
          collection: Collections.notes,
          id: 'bad',
          data: {'title': 42},
          updatedAt: 1,
        ),
        dirty: true,
      );
      engine.put(Collections.notes, 'good', {'title': 'Good'});
      expect(engine.records(Collections.notes).map((r) => r.id), ['good']);
      expect(engine.record(Collections.notes, 'bad'), isNull);
      await engine.sync();
      expect(engine.status.state, SyncState.idle);
      expect(records.get(Collections.notes, 'good'), isNotNull);
      expect(local.get(Collections.notes, 'bad')?.record.data['title'], 42);
    },
  );
}
