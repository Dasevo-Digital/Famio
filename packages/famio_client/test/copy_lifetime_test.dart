import 'dart:async';
import 'package:famio_client/famio_client.dart';
import 'package:famio_client/src/platform/memory_records.dart';
import 'package:famio_client/src/snapshot_codec.dart';
import 'package:test/test.dart';

void main() {
  test('disabling waits for the old write and deletes last', () async {
    final writing = Completer<void>(), release = Completer<void>();
    StoreSnapshot? copy;
    final backend = MemoryRecordBackend(
      newId(),
      null,
      writeCopy: (_, value, _) async {
        writing.complete();
        await release.future;
        copy = value;
      },
      deleteCopy: (_) async {
        copy = null;
      },
    );
    backend.put(
      const SyncRecord(
        collection: Collections.notes,
        id: 'note',
        data: {'title': 'Private'},
        updatedAt: 1,
      ),
      dirty: false,
    );
    backend.keepCopy(true);
    await writing.future;
    backend.keepCopy(false);
    release.complete();
    await backend.copyIdle;
    expect(copy, isNull);
    backend.close();
    await backend.copyIdle;
    expect(copy, isNull);
  });
  test('a new store revokes old timers and close callbacks', () async {
    final name = newId();
    StoreSnapshot? copy;
    MemoryRecordBackend backend() => MemoryRecordBackend(
      name,
      null,
      writeCopy: (_, value, _) async {
        copy = value;
      },
      deleteCopy: (_) async {
        copy = null;
      },
    );
    final old = backend()..keepCopy(true);
    await old.copyIdle;
    final next = backend()..keepCopy(false);
    await next.copyIdle;
    old.put(
      const SyncRecord(
        collection: Collections.notes,
        id: 'stale',
        data: {'title': 'Stale'},
        updatedAt: 1,
      ),
      dirty: true,
    );
    old.close();
    await old.copyIdle;
    expect(copy, isNull);
    next.keepCopy(true);
    next.put(
      const SyncRecord(
        collection: Collections.notes,
        id: 'new',
        data: {'title': 'New'},
        updatedAt: 2,
      ),
      dirty: false,
    );
    next.close();
    await next.copyIdle;
    expect(copy!.records.single.$1.id, 'new');
    old.close();
    await old.copyIdle;
    expect(copy!.records.single.$1.id, 'new');
  });
}
