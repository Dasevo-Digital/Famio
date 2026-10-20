import 'dart:typed_data';

import 'package:famio_client/famio_client.dart';
import 'package:famio_client/src/snapshot_codec.dart';
import 'package:test/test.dart';

void main() {
  test('a snapshot keeps records, their flag and the metadata', () {
    final record = SyncRecord(
      collection: Collections.tasks,
      id: 't1',
      data: {'title': 'Müll', 'visibleTo': null},
      updatedAt: 7,
      rev: 3,
    );
    final bytes = encodeSnapshot((
      records: [(record, true)],
      meta: {'lastRev': '3', 'members': '[]'},
    ));
    final back = decodeSnapshot(bytes)!;
    final (r, dirty) = back.records.single;
    expect(
      (r.collection, r.id, r.data['title'], r.rev, dirty),
      (Collections.tasks, 't1', 'Müll', 3, true),
    );
    expect(back.meta, {'lastRev': '3', 'members': '[]'});
    expect(decodeSnapshot(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('the apps keep no browser copy and open as usual', () async {
    final store = await LocalStore.openWithBrowserCopy(':memory:');
    store
      ..keepInBrowser(true)
      ..setMeta('lastRev', '1');
    expect(store.getMeta('lastRev'), '1');
  });
}
