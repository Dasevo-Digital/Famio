import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

SyncRecord record(String collection, Map<String, Object?> data) =>
    SyncRecord(collection: collection, id: 'fixture', data: data, updatedAt: 1);

void main() {
  test('malformed known fields and nested lists are rejected', () {
    for (final r in [
      record(Collections.notes, {'title': 42}),
      record(Collections.tasks, {
        'title': 'Task',
        'assigneeIds': [42],
      }),
      record(Collections.notes, {
        'title': 'Note',
        'visibleTo': [42],
      }),
      record(Collections.inbox, {
        'files': [42],
      }),
      record(Collections.tasks, {
        'photos': [
          {'id': 'f', 'size': 'large'},
        ],
      }),
      record(Collections.budgetSettings, {
        'limits': {'food': 'many'},
      }),
    ]) {
      expect(recordDataIsValid(r), isFalse, reason: r.collection);
    }
  });

  test(
    'partial older records and unknown extension fields remain compatible',
    () {
      final r = record(Collections.notes, {
        'title': 'Note',
        'future': {
          'x': [1, 2],
        },
      });
      validateRecordData(r);
      expect(r.data['future'], {
        'x': [1, 2],
      });
      expect(recordDataIsValid(record(Collections.tasks, {})), isTrue);
      expect(
        recordDataIsValid(
          SyncRecord(
            collection: Collections.notes,
            id: 'gone',
            data: {},
            updatedAt: 1,
            deleted: true,
          ),
        ),
        isTrue,
      );
    },
  );

  test('only actual supported attachment fields confer file access', () {
    expect(recordFileIds(record(Collections.notes, {'text': 'f'})), isEmpty);
    expect(
      recordFileIds(
        record(Collections.tasks, {
          'notes': 'f',
          'file': {'id': 'f'},
        }),
      ),
      isEmpty,
    );
    expect(
      recordFileIds(
        record(Collections.tasks, {
          'photos': [
            {'id': 'f'},
          ],
        }),
      ),
      ['f'],
    );
    expect(
      recordFileIds(
        record(Collections.inbox, {
          'files': [
            {'id': 'g'},
          ],
        }),
      ),
      ['g'],
    );
  });

  test('current recommendations preserve historic vaccination labels', () {
    expect(vaccinations.any((v) => v.id == 'menc'), isFalse);
    expect(vaccinations.singleWhere((v) => v.id == 'menacwy').ageMonths, 144);
    expect(vaccinationById('menc')?.title, 'Meningokokken C');
    for (final (id, from, to) in [
      ('us1', 8, 11),
      ('us2', 18, 21),
      ('us3', 28, 31),
    ]) {
      final task = pregnancyTasks.singleWhere((t) => t.id == id);
      expect((task.fromWeek, task.toWeek), (from, to));
    }
  });
}
