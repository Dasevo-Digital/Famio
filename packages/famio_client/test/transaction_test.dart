import 'dart:io';
import 'package:famio_client/famio_client.dart';
import 'package:famio_client/src/platform/memory_records.dart';
import 'package:test/test.dart';

void main() {
  for (final browser in [false, true]) {
    test(
      'failed transaction restores records, flags and metadata (${browser ? 'browser' : 'native'})',
      () {
        final directory = Directory.systemTemp.createTempSync(
          'famio-transaction-',
        );
        final path = '${directory.path}/records.db';
        final backend = MemoryRecordBackend(
          'test',
          null,
          writeCopy: (_, _) async {},
          deleteCopy: (_) async {},
        );
        final store = browser
            ? LocalStore.fromBackend(backend)
            : LocalStore.open(path);
        addTearDown(() {
          store.close();
          directory.deleteSync(recursive: true);
        });
        SyncRecord note(String id, String title) => SyncRecord(
          collection: Collections.notes,
          id: id,
          data: {'title': title},
          updatedAt: 1,
        );
        store.put(note('edit', 'Original'), dirty: true);
        store.put(note('remove', 'Retained'), dirty: false);
        store.setMeta('revision', 'before');
        expect(
          () => store.transaction(() {
            store.markClean(Collections.notes, 'edit');
            store.put(note('edit', 'Changed'), dirty: false);
            store.remove(Collections.notes, 'remove');
            store.put(note('phantom', 'Never committed'), dirty: true);
            store.setMeta('revision', 'after');
            store.setMeta('phantom', 'after');
            throw StateError('Abort');
          }),
          throwsStateError,
        );
        void verify(LocalStore value) {
          expect(
            value.get(Collections.notes, 'edit')!.record.data['title'],
            'Original',
          );
          expect(value.get(Collections.notes, 'edit')!.dirty, isTrue);
          expect(value.get(Collections.notes, 'remove'), isNotNull);
          expect(value.get(Collections.notes, 'phantom'), isNull);
          expect(value.getMeta('revision'), 'before');
          expect(value.getMeta('phantom'), isNull);
        }

        verify(store);
        final reopened = browser
            ? LocalStore.fromBackend(backend)
            : LocalStore.open(path);
        verify(reopened);
        if (!browser) reopened.close();
        store.transaction(
          () => store.put(note('committed', 'Saved'), dirty: true),
        );
        expect(store.get(Collections.notes, 'committed'), isNotNull);
      },
    );
  }
}
