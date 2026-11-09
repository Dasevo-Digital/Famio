import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/lists/list_provider.dart';
import 'package:famio_server/src/lists/list_sync.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

class _Provider implements ListProvider {
  @override
  final String kind = 'mstodo';
  @override
  final bool oneEntryPerTitle = false;
  @override
  bool get hasDueDates => true;
  @override
  bool get hasSteps => true;
  @override
  Map<String, Object?> get credentials => const {'token': 'x'};
  final entries = <String, RemoteItem>{};
  var writes = 0;
  var n = 0;
  @override
  Future<List<RemoteList>> lists() async => const [
    RemoteList(id: 'L', name: 'L'),
  ];
  @override
  Future<List<RemoteItem>> items(String listId) async => [...entries.values];
  @override
  Future<RemoteItem> create(String listId, ItemDraft item) async {
    writes++;
    final id = 'r${n++}';
    return entries[id] = RemoteItem(
      id: id,
      title: item.title,
      note: item.note,
      done: item.done,
      modified: DateTime.now(),
    );
  }

  @override
  Future<void> update(
    String listId,
    RemoteItem previous,
    ItemDraft item,
  ) async {
    writes++;
    entries[previous.id] = RemoteItem(
      id: previous.id,
      title: item.title,
      note: item.note,
      done: item.done,
      modified: DateTime.now(),
    );
  }

  @override
  Future<void> delete(String listId, RemoteItem item) async {
    writes++;
    entries.remove(item.id);
  }
}

/// What a member may not see does not go out to a connected list service.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, kid;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    kid = app.accounts.create(
      username: 'kid',
      displayName: 'Kid',
      role: MemberRole.child,
    );
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  SyncRecord event({bool confidential = false}) => SyncRecord(
    collection: Collections.events,
    id: 'e1',
    data: {
      'title': 'Klinik',
      'start': '2026-12-01T10:00:00.000Z',
      'end': '2026-12-01T11:00:00.000Z',
      'confidential': confidential,
      'memberIds': <String>[],
    },
    updatedAt: clock += 1000,
  );

  SyncRecord list() => SyncRecord(
    collection: Collections.shoppingLists,
    id: 'l1',
    data: const ShoppingList(
      id: 'l1',
      name: 'Koffer',
      packing: true,
      eventId: 'e1',
    ).toData(),
    updatedAt: clock += 1000,
  );

  SyncRecord item(String name) => SyncRecord(
    collection: Collections.shoppingItems,
    id: 'i1',
    data: ShoppingItem(id: 'i1', listId: 'l1', name: name).toData(),
    updatedAt: clock += 1000,
  );

  test('a list that became confidential stops going out', () async {
    final remote = _Provider();
    final lists = ListSync(
      db: app.db,
      records: app.records,
      timeZone: () => 'Europe/Berlin',
      onChanged: () {},
      enabled: () => true,
      providerFor: (_, _) => remote,
    );
    app.records.sync(
      SyncRequest(since: 0, changes: [event(), list(), item('Zahnbuerste')]),
      mama.id,
    );
    app.db.execute(
      'INSERT INTO list_accounts (id, user_id, provider, name, credentials,'
      ' created_at) VALUES (?, ?, ?, ?, ?, 0)',
      ['acc', kid.id, 'mstodo', 'Kid', '{}'],
    );
    lists.setLinks('acc', kid.id, [
      {'famioList': 'l1', 'remoteList': 'L', 'remoteName': 'Pack'},
    ]);
    await lists.syncAccount('acc');
    expect(remote.entries.values.map((e) => e.title), ['Zahnbuerste']);

    app.records.sync(
      SyncRequest(
        since: 0,
        changes: [event(confidential: true), item('Ueberweisung')],
      ),
      mama.id,
    );
    await lists.syncAccount('acc');
    expect(
      remote.entries.values.map((e) => e.title),
      isNot(contains('Ueberweisung')),
    );
  });
}
