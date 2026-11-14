import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// A local copy encrypted with another device's key – a phone restored from
/// the backup of another one – cannot be read; the app starts it anew and
/// fetches it from the server, instead of failing at every start (#490).
void main() {
  const mine =
      '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
  const other =
      'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('famio-unreadable'));
  tearDown(() => dir.deleteSync(recursive: true));

  SyncRecord note(String id) => SyncRecord(
    collection: Collections.notes,
    id: id,
    data: {'title': id},
    updatedAt: 1,
  );

  test('records: another key starts over, the same keeps them', () {
    final path = '${dir.path}/famio_m1.db';
    LocalStore.open(path, hexKey: other)
      ..put(note('n1'), dirty: false)
      ..close();
    expect(
      () => LocalStore.open(path, hexKey: mine),
      throwsA(isA<SqliteException>()),
      reason: 'only when asked to',
    );
    final store = LocalStore.open(
      path,
      hexKey: mine,
      unreadable: UnreadableDatabase.reset,
    );
    expect(store.get(Collections.notes, 'n1'), isNull);
    store
      ..put(note('n2'), dirty: false)
      ..close();
    final again = LocalStore.open(
      path,
      hexKey: mine,
      unreadable: UnreadableDatabase.reset,
    );
    expect(again.get(Collections.notes, 'n2'), isNotNull);
    again.close();
  });

  test('the file cache likewise', () async {
    final path = '${dir.path}/files_m1.db';
    final api = FamioApiClient('localhost:1');
    FileCache.open(
      path,
      api,
      hexKey: other,
      tempDir: '${dir.path}/tmp',
    ).close();
    final cache = FileCache.open(
      path,
      api,
      hexKey: mine,
      tempDir: '${dir.path}/tmp',
      unreadable: UnreadableDatabase.reset,
    );
    cache.close();
  });

  test('a damaged copy with this key is set aside, not deleted', () {
    final path = '${dir.path}/famio_m1.db';
    LocalStore.open(path, hexKey: mine)
      ..put(note('n1'), dirty: true)
      ..close();
    // Damage the first page, size unchanged.
    final raf = File(path).openSync(mode: FileMode.append);
    raf.setPositionSync(16);
    raf.writeFromSync(List.filled(48, 0));
    raf.closeSync();
    takeSetAsideDatabases();
    final store = LocalStore.open(
      path,
      hexKey: mine,
      unreadable: UnreadableDatabase.setAside,
    );
    expect(store.get(Collections.notes, 'n1'), isNull);
    store.close();
    expect(takeSetAsideDatabases(), ['$path.unreadable']);
    expect(File('$path.unreadable').existsSync(), isTrue);
    expect(takeSetAsideDatabases(), isEmpty);
  });

  test('without a choice it stays an error', () {
    final path = '${dir.path}/famio_m1.db';
    LocalStore.open(path, hexKey: other).close();
    expect(
      () => LocalStore.open(path, hexKey: mine),
      throwsA(isA<SqliteException>()),
    );
    expect(File(path).existsSync(), isTrue);
  });
}
