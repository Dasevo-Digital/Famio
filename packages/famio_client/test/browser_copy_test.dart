// The web app's copy of its store, in a real browser (IndexedDB, WebCrypto):
//   dart test -p firefox test/browser_copy_test.dart
@TestOn('browser')
library;

import 'dart:typed_data';
import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'package:famio_client/famio_client.dart';
import 'package:famio_client/src/platform/browser_copy.dart';
import 'package:famio_client/src/platform/browser_copy_web.dart' as raw;
import 'package:test/test.dart';

SyncRecord _task(String id, String title) => SyncRecord(
  collection: Collections.tasks,
  id: id,
  data: {'title': title},
  updatedAt: 1,
);

void main() {
  test(
    'an old uncoordinated writer cannot reopen the upgraded database',
    () async {
      final name = 'upgrade-${newId()}.db';
      await raw.enableBrowserCopy(name, 'upgraded-session');
      final refused = Completer<String?>();
      final request = web.window.indexedDB.open('famio-browser-copy', 1);
      request.onerror = ((web.Event _) {
        refused.complete(request.error?.name);
      }).toJS;
      request.onsuccess = ((web.Event _) {
        (request.result as web.IDBDatabase).close();
        refused.complete(null);
      }).toJS;
      expect(await refused.future, 'VersionError');
      await raw.deleteBrowserCopy(name);
    },
  );
  test(
    'a revoked persistent lease cannot recreate a copy or overwrite a new session',
    () async {
      final name = 'lease-${newId()}.db';
      final old = Uint8List.fromList([1, 2, 3]);
      final fresh = Uint8List.fromList([4, 5, 6]);
      await raw.enableBrowserCopy(name, 'old-session');
      await raw.writeBrowserCopy(name, old, 'old-session');
      await raw.deleteBrowserCopy(name);
      await raw.writeBrowserCopy(name, old, 'old-session');
      expect(await raw.readBrowserCopy(name), isNull);
      await raw.enableBrowserCopy(name, 'new-session');
      await raw.writeBrowserCopy(name, fresh, 'new-session');
      await raw.writeBrowserCopy(name, old, 'old-session');
      expect(await raw.readBrowserCopy(name), fresh);
      await raw.deleteBrowserCopy(name);
    },
  );
  test('encrypted copy: written, read, deleted with its key', () async {
    const name = 'test-copy.db';
    await deleteBrowserCopy(name);
    expect(await readBrowserCopy(name), isNull);
    final plain = Uint8List.fromList('Famio'.codeUnits);
    await writeBrowserCopy(name, plain);
    expect(await readBrowserCopy(name), plain);
    // A new IV each time: the same text is stored differently.
    await writeBrowserCopy(name, plain);
    expect(await readBrowserCopy(name), plain);
    await deleteBrowserCopy(name);
    expect(await readBrowserCopy(name), isNull);
  });

  test('the store starts from its copy and forgets it on request', () async {
    const path = 'famio_test-member.db';
    await LocalStore.deleteBrowserCopy(path);
    final first = await LocalStore.openWithBrowserCopy(path);
    expect(first.all(Collections.tasks), isEmpty);
    first
      ..keepInBrowser(true)
      ..put(_task('t1', 'Müll'), dirty: false)
      ..put(_task('t2', 'Neu'), dirty: true)
      ..setMeta('lastRev', '42');
    // Written a moment after the last change.
    await Future<void>.delayed(const Duration(seconds: 3));

    final again = await LocalStore.openWithBrowserCopy(path);
    expect(
      {for (final r in again.all(Collections.tasks)) r.record.id: r.dirty},
      {'t1': false, 't2': true},
    );
    expect(again.getMeta('lastRev'), '42');

    again.keepInBrowser(false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final empty = await LocalStore.openWithBrowserCopy(path);
    expect(empty.all(Collections.tasks), isEmpty);
    // Without asking for it, nothing is kept.
    empty.put(_task('t3', 'Flüchtig'), dirty: false);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(
      (await LocalStore.openWithBrowserCopy(path)).all(Collections.tasks),
      isEmpty,
    );
  });
}
