import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('confirmation settings survive task and detached event edits', () {
    const setting = AssignmentSettings(required: true, remindMinutes: 1440);
    final task = Task(
      id: 'task',
      title: 'Task',
      assignmentConfirmation: setting,
    );
    final storedTask = SyncRecord(
      collection: Collections.tasks,
      id: task.id,
      data: task.toData(),
      updatedAt: 1,
    );
    expect(
      Task.fromRecord(
        storedTask,
      ).copyWith(title: 'Edited').assignmentConfirmation.remindMinutes,
      1440,
    );
    final event = CalendarEvent(
      id: 'event',
      title: 'Event',
      start: DateTime(2027),
      end: DateTime(2027),
      assignmentConfirmation: setting,
    );
    final storedEvent = SyncRecord(
      collection: Collections.events,
      id: event.id,
      data: event.toData(),
      updatedAt: 1,
    );
    expect(
      CalendarEvent.fromRecord(storedEvent)
          .withId('detached')
          .copyWith(title: 'Edited')
          .assignmentConfirmation
          .required,
      isTrue,
    );
    expect(
      recordDataIsValid(
        storedTask.copyWith(
          data: {
            ...storedTask.data,
            'assignmentConfirmation': {'required': true, 'remindMinutes': -1},
          },
        ),
      ),
      isFalse,
    );
    expect(
      recordDataIsValid(
        storedTask.copyWith(
          data: {
            ...storedTask.data,
            'assignmentConfirmation': {'required': 'yes'},
          },
        ),
      ),
      isFalse,
    );
  });

  test(
    'semantic changes require a new reply but key order and visibility do not',
    () {
      final original = SyncRecord(
        collection: Collections.tasks,
        id: 'task',
        updatedAt: 1,
        data: Task(
          id: 'task',
          title: 'Help',
          assigneeIds: const ['member'],
          assignmentConfirmation: const AssignmentSettings(required: true),
        ).toData(),
      );
      final request = assignmentRequests(original).single;
      final reordered = original.copyWith(
        data: Map.fromEntries(original.data.entries.toList().reversed),
      );
      expect(
        assignmentRequests(reordered).single.fingerprint,
        request.fingerprint,
      );
      final visible = original.copyWith(
        data: {
          ...original.data,
          'visibleTo': ['member'],
        },
      );
      expect(
        assignmentRequests(visible).single.fingerprint,
        request.fingerprint,
      );
      final edited = original.copyWith(
        data: {...original.data, 'title': 'Something else'},
      );
      expect(
        assignmentRequests(edited).single.fingerprint,
        isNot(request.fingerprint),
      );
      expect(request.id.length, lessThanOrEqualTo(64));
      expect(assignmentRequests(original.copyWith(deleted: true)), isEmpty);
    },
  );

  test('old or unassigned records never request an implicit confirmation', () {
    final old = SyncRecord(
      collection: Collections.tasks,
      id: 'task',
      updatedAt: 1,
      data: {'title': 'Old', 'assigneeId': 'member'},
    );
    expect(assignmentRequests(old), isEmpty);
    final noPerson = Task(
      id: 'task',
      title: 'For all',
      assignmentConfirmation: const AssignmentSettings(required: true),
    );
    expect(assignmentRequests(old.copyWith(data: noPerson.toData())), isEmpty);
  });
}
