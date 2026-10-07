import 'package:famio_client/famio_client.dart';
import 'package:test/test.dart';

void main() {
  final from = DateTime(2026, 10, 1, 12);
  final to = DateTime(2026, 10, 8, 12);

  test('event reminders respect participants and offsets', () {
    final events = [
      CalendarEvent(
        id: 'sport',
        title: 'Fußball',
        start: DateTime(2026, 9, 1, 17),
        end: DateTime(2026, 9, 1, 18),
        memberIds: const ['kid'],
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
        reminderMinutes: 60,
      ),
      CalendarEvent(
        id: 'family',
        title: 'Oma Geburtstag',
        start: DateTime(2026, 10, 3),
        end: DateTime(2026, 10, 4),
        allDay: true,
        reminderMinutes: 0,
      ),
      CalendarEvent(
        id: 'none',
        title: 'Ohne Erinnerung',
        start: DateTime(2026, 10, 2, 9),
        end: DateTime(2026, 10, 2, 10),
      ),
    ];

    final forKid = upcomingReminders(
      events: events,
      tasks: const [],
      memberId: 'kid',
      from: from,
      to: to,
    );
    // 1 Sep is a Tuesday: 6 Oct 16:00, plus the birthday on 3 Oct.
    expect(
      [for (final r in forKid) r.at],
      [DateTime(2026, 10, 3), DateTime(2026, 10, 6, 16)],
    );

    final forMum = upcomingReminders(
      events: events,
      tasks: const [],
      memberId: 'mum',
      from: from,
      to: to,
    );
    expect([for (final r in forMum) r.title], ['Oma Geburtstag']);
  });

  test('reminder just before a running event is not in the past', () {
    final events = [
      CalendarEvent(
        id: 'now',
        title: 'Läuft schon',
        start: from.subtract(const Duration(minutes: 10)),
        end: from.add(const Duration(hours: 1)),
        reminderMinutes: 5,
      ),
    ];
    expect(
      upcomingReminders(
        events: events,
        tasks: const [],
        memberId: 'x',
        from: from,
        to: to,
      ),
      isEmpty,
    );
  });

  test('task reminders go to the assignee and skip done tasks', () {
    final at = DateTime(2026, 10, 2, 18);
    final tasks = [
      Task(id: '1', title: 'Müll', remindAt: at, assigneeId: 'kid'),
      Task(id: '2', title: 'Alle', remindAt: at),
      Task(id: '3', title: 'Erledigt', remindAt: at, done: true),
      Task(id: '4', title: 'Vergangen', remindAt: DateTime(2026, 9, 1)),
    ];
    final titles = [
      for (final r in upcomingReminders(
        events: const [],
        tasks: tasks,
        memberId: 'mum',
        from: from,
        to: to,
      ))
        r.title,
    ];
    expect(titles, ['Alle']);
  });

  test('notification ids are stable and positive', () {
    final r = DueReminder(key: 'event:abc', at: from, title: 't');
    expect(
      r.notificationId,
      DueReminder(key: 'event:abc', at: to, title: 'x').notificationId,
    );
    expect(r.notificationId, isNonNegative);
    expect(
      r.notificationId,
      isNot(DueReminder(key: 'event:abd', at: from, title: 't').notificationId),
    );
  });

  test('lifts remind the one who brings and the one who picks up', () {
    final training = CalendarEvent(
      id: 'e',
      title: 'Training',
      start: DateTime(2026, 10, 8, 17),
      end: DateTime(2026, 10, 8, 18, 30),
      bringerId: 'papa',
      pickerId: 'mama',
    );
    List<(String, DateTime)> forMember(String id) => [
      for (final r in upcomingReminders(
        events: [training],
        tasks: const [],
        memberId: id,
        from: DateTime(2026, 10, 8),
        to: DateTime(2026, 10, 9),
      ))
        (r.title, r.at),
    ];
    expect(forMember('papa'), [
      ('🚗 Bringen: Training', DateTime(2026, 10, 8, 16, 30)),
    ]);
    expect(forMember('mama'), [
      ('🚗 Abholen: Training', DateTime(2026, 10, 8, 18, 15)),
    ]);
    expect(forMember('mia'), isEmpty);
    final back = CalendarEvent.fromRecord(
      SyncRecord(
        collection: 'events',
        id: 'e',
        data: training.toData(),
        updatedAt: 1,
      ),
    );
    expect((back.bringerId, back.pickerId), ('papa', 'mama'));
    expect(back.copyWith(pickerId: null).pickerId, isNull);
  });
}
