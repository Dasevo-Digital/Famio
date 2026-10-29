import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  const old = FileRef(id: 'file', name: 'old', mime: 'text/plain', size: 1);
  const canonical = FileRef(
    id: 'file',
    name: 'fixture.bin',
    mime: 'application/octet-stream',
    size: 4,
  );
  test(
    'only typed attachment fields are mapped and unknown fields survive',
    () {
      for (final (collection, field, plural) in [
        (Collections.documents, 'file', false),
        (Collections.tasks, 'photos', true),
        (Collections.inbox, 'files', true),
        (Collections.children, 'photo', false),
        (Collections.chatMessages, 'attachment', false),
      ]) {
        final value = {...old.toJson(), 'future': true};
        final record = SyncRecord(
          collection: collection,
          id: 'record',
          updatedAt: 1,
          data: {
            field: plural ? [value] : value,
            'text': 'file',
            'unknown': old.toJson(),
          },
        );
        final result = mapRecordFiles(record, (_) => canonical);
        expect(
          result.data[field],
          plural
              ? [
                  {...canonical.toJson(), 'future': true},
                ]
              : {...canonical.toJson(), 'future': true},
        );
        expect(result.data['unknown'], old.toJson());
        expect(recordFileIds(result), ['file']);
      }
    },
  );
  test(
    'conflict snapshots keep their audience and unknown historical fields',
    () {
      final record = SyncRecord(
        collection: Collections.conflicts,
        id: 'conflict',
        updatedAt: 1,
        data: {
          'collection': Collections.documents,
          'recordId': 'document',
          'lost': {'file': old.toJson(), 'unknown': true},
          SyncRecord.visibilityKey: ['member'],
          'future': 7,
        },
      );
      final result = mapRecordFiles(record, (_) => canonical);
      expect((result.data['lost'] as Map)['file'], canonical.toJson());
      expect((result.data['lost'] as Map)['unknown'], isTrue);
      expect(result.visibleTo, ['member']);
      expect(result.data['future'], 7);
    },
  );
  test('tombstones and unresolved file identities remain unchanged', () {
    final record = SyncRecord(
      collection: Collections.documents,
      id: 'document',
      updatedAt: 1,
      data: {'file': old.toJson()},
    );
    expect(identical(mapRecordFiles(record, (file) => file), record), isTrue);
    final deleted = record.copyWith(deleted: true);
    expect(
      identical(
        mapRecordFiles(deleted, (_) => throw StateError('Must not resolve')),
        deleted,
      ),
      isTrue,
    );
  });
}
