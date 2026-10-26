import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/school_bag.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"}]';

SyncEngine _engine(String memberId) => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: memberId,
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('the evening before each school day: subjects and things', () {
    final mia = Child(
      id: 'c1',
      name: 'Mia',
      birthDate: DateTime(2018, 3, 1),
      guardianIds: const ['m1'],
    );
    var table = Timetable(childId: 'c1')
        .withLesson(DateTime.monday, 0, 'Mathe')
        .withLesson(DateTime.monday, 1, 'Sport')
        .withLesson(DateTime.monday, 2, 'Sport')
        .withLesson(DateTime.tuesday, 0, 'Deutsch')
        .withLesson(DateTime.tuesday, 1, 'Musik')
        .withLesson(DateTime.thursday, 0, 'Kunst')
        .withBring('Sport', 'Sportzeug')
        .withBring('Musik', 'Flöte')
        .withBring('Kunst', 'Malkasten');
    SyncEngine engine(String member) => _engine(member)
      ..saveChild(mia)
      ..saveTimetable(table)
      ..saveEvent(
        CalendarEvent(
          id: 'e1',
          title: 'Wandertag Mia',
          start: DateTime(2026, 11, 3),
          end: DateTime(2026, 11, 4),
          allDay: true,
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'e2',
          title: 'Miami-Abend',
          start: DateTime(2026, 11, 3, 19),
          end: DateTime(2026, 11, 3, 21),
        ),
      )
      // Thursday off: a family holiday.
      ..saveVacation(
        Vacation(
          id: 'v',
          from: DateTime(2026, 11, 5),
          to: DateTime(2026, 11, 5),
        ),
      );
    Map<String, (DateTime, String, String?)> bags(SyncEngine e) => {
      for (final r in familyReminders(
        e,
        from: DateTime(2026, 11, 1, 12),
        to: DateTime(2026, 11, 8),
      ))
        if (r.key.startsWith('bag:')) r.key: (r.at, r.title, r.body),
    };

    // Off until switched on.
    expect(bags(engine('m1')), isEmpty);
    table = table.withBagCheck('19:15');
    expect(bags(engine('m1')), {
      'bag:c1:2026-11-02': (
        DateTime(2026, 11, 1, 19, 15),
        'Schulranzen für morgen: Mia',
        'Mathe, Sport · Mitnehmen: Sportzeug',
      ),
      'bag:c1:2026-11-03': (
        DateTime(2026, 11, 2, 19, 15),
        'Schulranzen für morgen: Mia',
        'Deutsch, Musik · Mitnehmen: Flöte · Wandertag Mia',
      ),
    });
    // Only for the child's people.
    expect(bags(engine('m2')), isEmpty);
    expect(schoolBag(engine('m1'), mia, DateTime(2026, 11, 7)), isNull);
  });

  test('times are read only when valid', () {
    expect(parseClock('18:30'), (18, 30));
    expect(parseClock('7:05'), (7, 5));
    expect(parseClock('24:00'), isNull);
    expect(parseClock(null), isNull);
    expect(
      Timetable.fromRecord(
        SyncRecord(
          collection: Collections.timetables,
          id: 'c1',
          data: Timetable(
            childId: 'c1',
          ).withBring('Sport', 'Sportzeug').withBagCheck('18:30').toData(),
          updatedAt: 1,
        ),
      ).toData(),
      containsPair('bring', {'Sport': 'Sportzeug'}),
    );
  });
}
