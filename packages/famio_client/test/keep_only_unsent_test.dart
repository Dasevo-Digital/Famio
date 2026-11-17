import 'package:famio_client/famio_client.dart';
import 'package:test/test.dart';

/// A session that ended elsewhere keeps only what was not sent yet (#560).
void main() {
  test('keeps unsent changes, drops the rest and what the device knew', () {
    final store = LocalStore.open(':memory:')
      ..setMeta('members', '[]')
      ..setMeta('lastRev', '42')
      ..setMeta('syncScope', 'adult')
      ..setMeta('familyTimeZone', 'Europe/Berlin');
    SyncRecord record(String collection, String id, {bool deleted = false}) =>
        SyncRecord(
          collection: collection,
          id: id,
          data: deleted ? const {} : {'title': id},
          deleted: deleted,
          updatedAt: 1,
          rev: 1,
        );
    store
      ..put(record(Collections.medications, 'med'), dirty: false)
      ..put(record(Collections.notes, 'note'), dirty: false)
      ..put(record(Collections.tasks, 'new'), dirty: true)
      ..put(record(Collections.notes, 'gone', deleted: true), dirty: true);
    final engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine.keepOnlyUnsent();
    expect(store.keys.toSet(), {
      (Collections.tasks, 'new'),
      (Collections.notes, 'gone'),
    });
    expect(store.dirty, hasLength(2));
    expect(store.getMeta('members'), isNull);
    expect(store.getMeta('lastRev'), isNull);
    expect(store.getMeta('syncScope'), isNull);
    // What is no one's data stays.
    expect(store.getMeta('familyTimeZone'), 'Europe/Berlin');
    expect(engine.lastRev, 0);
    store.close();
  });
}
