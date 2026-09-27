import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('newId produces v4 uuids', () {
    final id = newId();
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(newId(), isNot(id));
  });

  test('last writer wins with deterministic tie break', () {
    const a = SyncRecord(
      collection: 'tasks',
      id: '1',
      data: {},
      updatedAt: 10,
      updatedBy: 'a',
    );
    final b = a.copyWith(updatedAt: 11, updatedBy: 'b');
    expect(b.winsOver(a), isTrue);
    expect(a.winsOver(b), isFalse);
    final tie = a.copyWith(updatedBy: 'b');
    expect(tie.winsOver(a), isTrue);
    expect(a.winsOver(tie), isFalse);
  });

  test('task roundtrip', () {
    final task = Task(
      id: 'x',
      title: 'Müll raus',
      due: DateTime.utc(2026, 10, 1),
    );
    final record = SyncRecord(
      collection: Collections.tasks,
      id: task.id,
      data: task.toData(),
      updatedAt: 1,
    );
    final back = Task.fromRecord(SyncRecord.fromJson(record.toJson()));
    expect(back.title, 'Müll raus');
    expect(back.due, DateTime.utc(2026, 10, 1));
  });

  test('task copyWith keeps or clears nullable fields', () {
    final task = Task(
      id: 'x',
      title: 'a',
      due: DateTime(2026),
      assigneeId: 'm',
    );
    expect(task.copyWith(title: 'b').due, DateTime(2026));
    expect(task.copyWith(due: null).due, isNull);
    expect(task.copyWith(due: null).assigneeId, 'm');
  });
}
