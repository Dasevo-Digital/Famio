import 'package:famio/src/data/free_slots.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Occurrence at(
    String title,
    DateTime start,
    DateTime end, {
    List<String> who = const [],
    bool allDay = false,
    String? bringer,
  }) {
    final e = CalendarEvent(
      id: title,
      title: title,
      start: start,
      end: end,
      allDay: allDay,
      memberIds: who,
      bringerId: bringer,
    );
    return Occurrence(e, start, end);
  }

  final monday = DateTime(2026, 10, 19, 7);

  test('gaps between the appointments of the people asked', () {
    final slots = freeSlots(
      occurrences: [
        at(
          'Arbeit Mama',
          DateTime(2026, 10, 19, 8),
          DateTime(2026, 10, 19, 16, 10),
          who: ['mama'],
        ),
        at(
          'Training',
          DateTime(2026, 10, 19, 17),
          DateTime(2026, 10, 19, 18, 30),
          who: ['kind'],
          bringer: 'papa',
        ),
        // Someone else's appointment does not count.
        at(
          'Friseur Oma',
          DateTime(2026, 10, 19, 19),
          DateTime(2026, 10, 19, 20),
          who: ['oma'],
        ),
        // All-day entries do not block.
        at(
          'Geburtstag',
          DateTime(2026, 10, 19),
          DateTime(2026, 10, 20),
          allDay: true,
        ),
      ],
      memberIds: {'mama', 'papa'},
      from: monday,
      days: 1,
      length: const Duration(minutes: 45),
      endHour: 21,
    );
    // Mama works until 16:10 (rounded to 16:15), 45 minutes fit exactly
    // before Papa brings the child to training.
    expect(slots.map((s) => (s.start.hour, s.start.minute)), [
      (16, 15),
      (18, 30),
    ]);
  });

  test('a family appointment blocks everyone; days run on calendar days', () {
    final slots = freeSlots(
      occurrences: [
        at(
          'Familienessen',
          DateTime(2026, 10, 24, 8),
          DateTime(2026, 10, 24, 20),
        ),
      ],
      memberIds: {'papa'},
      from: DateTime(2026, 10, 24, 6),
      days: 2,
      length: const Duration(hours: 2),
    );
    // Saturday is full; Sunday (25 hours, clock change) starts at 8:00.
    expect(slots.single.start, DateTime(2026, 10, 25, 8));
  });

  test('today starts at the next quarter hour', () {
    final slots = freeSlots(
      occurrences: const [],
      memberIds: {'papa'},
      from: DateTime(2026, 10, 19, 13, 7),
      days: 1,
      length: const Duration(hours: 1),
    );
    expect(slots.single.start, DateTime(2026, 10, 19, 13, 15));
  });
}
