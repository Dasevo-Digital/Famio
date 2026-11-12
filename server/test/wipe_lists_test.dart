import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/lists/list_sync.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'list_sync_test.dart' show FakeProvider;

/// "Alle Daten löschen" ends the list connections first: otherwise the next
/// run would take every wiped task for deleted in Famio and delete it in
/// Microsoft To Do as well.
void main() {
  test('wiping all data leaves the lists in other apps alone', () async {
    final app = FamioServerApp.inMemory();
    addTearDown(app.close);
    final setup = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/setup'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'username': 'mama',
          'password': 'tulpe-regal-7',
          'setupCode': app.setupCode,
        }),
      ),
    );
    final body = jsonDecode(await setup.readAsString()) as Map;
    final token = body['token'] as String;
    final mama = (body['member'] as Map)['id'] as String;
    final fake = FakeProvider();
    // A second instance on the same database, as the server's own one runs
    // with the real providers.
    final lists = ListSync(
      db: app.db,
      records: app.records,
      timeZone: () => 'Europe/Berlin',
      onChanged: () {},
      enabled: () => true,
      providerFor: (_, _) => fake,
    );
    app.db.execute(
      'INSERT INTO list_accounts (id, user_id, provider, name, credentials,'
      ' created_at) VALUES (?, ?, ?, ?, ?, 0)',
      ['acc', mama, 'mstodo', 'Test', '{}'],
    );
    fake.add('Steuererklärung');
    fake.add('Arzttermin vereinbaren');
    app.records.writeAs(mama, [
      SyncRecord(
        collection: Collections.tasks,
        id: 't1',
        data: Task(id: 't1', title: 'Müll').toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    lists.setLinks('acc', mama, [
      {'famioList': 'tasks', 'remoteList': 'L', 'remoteName': 'Aufgaben'},
    ]);
    await lists.syncAccount('acc');
    expect(fake.entries, hasLength(3));

    final wipe = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/admin/wipe'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({'confirm': 'LÖSCHEN', 'password': 'tulpe-regal-7'}),
      ),
    );
    expect(wipe.statusCode, 200);
    expect(
      app.db.select('SELECT count(*) AS n FROM list_accounts').first['n'],
      0,
    );
    await lists.syncAccount('acc');
    expect(fake.entries.values.map((e) => e.title), [
      'Steuererklärung',
      'Arzttermin vereinbaren',
      'Müll',
    ]);
  });
}
