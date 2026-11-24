import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:test/test.dart';

/// Single local writes (#493): each put used to wait for the disk with
/// the rollback journal (probe S8 after 2.0.53: 2000 puts 468 ms one by
/// one, 7 ms in one transaction).
void main() {
  test('the record database writes with a write-ahead log', () {
    final dir = Directory.systemTemp.createTempSync('famio_wal');
    addTearDown(() => dir.deleteSync(recursive: true));
    const key =
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
    final path = '${dir.path}/famio.db';
    final store = LocalStore.open(path, hexKey: key);
    SyncRecord r(int i) => SyncRecord(
      collection: Collections.childLogs,
      id: 'l$i',
      data: {'childId': 'c', 'kind': 'diaper', 'at': '2026-11-01T10:00:00Z'},
      updatedAt: i + 1,
    );
    final sw = Stopwatch()..start();
    for (var i = 0; i < 2000; i++) {
      store.put(r(i), dirty: true);
    }
    final loose = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('2000 single puts: $loose ms');
    expect(File('$path-wal').existsSync(), isTrue);
    store.close();

    // Still encrypted, and everything is there after reopening.
    expect(
      String.fromCharCodes(File(path).readAsBytesSync().take(15)),
      isNot('SQLite format 3'),
    );
    final again = LocalStore.open(path, hexKey: key);
    addTearDown(again.close);
    expect(again.dirty, hasLength(2000));
  });
}
