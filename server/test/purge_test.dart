import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  SyncRecord item(String id, {bool deleted = false, int at = 1}) => SyncRecord(
    collection: Collections.shoppingItems,
    id: id,
    data: deleted ? const {} : {'name': id},
    deleted: deleted,
    updatedAt: at,
  );

  test('deletion marks go after half a year by the server clock', () {
    final app = FamioServerApp.inMemory();
    final records = app.records;
    records.sync(SyncRequest(since: 0, changes: [item('a'), item('b')]), 'u1');
    records.sync(
      SyncRequest(since: 0, changes: [item('a', deleted: true, at: 2)]),
      'u1',
    );
    final t0 = DateTime(2026, 1, 1);
    // No mark half a year back yet: nothing goes.
    expect(records.purgeDeleted(now: t0), 0);
    expect(records.purgeDeleted(now: t0.add(const Duration(days: 179))), 0);
    final revBefore = records.currentRev;
    expect(records.purgeDeleted(now: t0.add(const Duration(days: 181))), 1);
    expect(records.get(Collections.shoppingItems, 'a'), isNull);
    expect(records.get(Collections.shoppingItems, 'b'), isNotNull);
    // Revisions never go back, even though the newest record is gone.
    expect(records.currentRev, revBefore);
    records.sync(SyncRequest(since: 0, changes: [item('c')]), 'u1');
    expect(records.currentRev, revBefore + 1);
  });

  test('only newer apps behind the cleanup start over', () {
    final app = FamioServerApp.inMemory();
    final records = app.records;
    records.sync(SyncRequest(since: 0, changes: [item('a'), item('b')]), 'u1');
    final behind = records.currentRev;
    records.sync(
      SyncRequest(since: 0, changes: [item('a', deleted: true, at: 2)]),
      'u1',
    );
    final t0 = DateTime(2026, 1, 1);
    records
      ..purgeDeleted(now: t0)
      ..purgeDeleted(now: t0.add(const Duration(days: 181)));

    // An app before 1.0.10 would ask again and again: no reset for it.
    final old = records.sync(SyncRequest(since: behind - 1), 'u1');
    expect(old.reset, isFalse);

    final fresh = records.sync(
      SyncRequest(since: behind - 1, resettable: true),
      'u1',
    );
    expect(fresh.reset, isTrue);
    expect(fresh.changes.map((r) => r.id), ['b']);
    // Further pages of a full download are no reason to start over.
    final page = records.sync(
      SyncRequest(since: 1, resettable: true, full: true),
      'u1',
    );
    expect(page.reset, isFalse);
    // Up to date: nothing to do.
    final current = records.sync(
      SyncRequest(since: records.currentRev, resettable: true),
      'u1',
    );
    expect(current.reset, isFalse);
    expect(current.changes, isEmpty);
  });
}
