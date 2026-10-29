import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/day_preview.dart';
import 'package:famio/src/data/week_preview.dart';
import 'package:famio/src/data/week_plan.dart';
import 'package:famio/src/data/year_review.dart';
import 'package:famio/src/data/birthdays.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest_all.dart' as zones;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  // The rules the server sends with the sync (calendar_zone_test in the
  // client package covers that path).
  setUpAll(zones.initializeTimeZones);
  for (final zone in [
    'Europe/Berlin',
    'America/New_York',
    'Pacific/Auckland',
    'Pacific/Kiritimati',
  ]) {
    test('civil days and previews agree in $zone', () async {
      final store = LocalStore.open(':memory:')
        ..setMeta('familyTimeZone', zone);
      final api = FamioApiClient('http://localhost');
      final engine = SyncEngine(store: store, api: api, memberId: 'member');
      addTearDown(() async {
        await engine.dispose();
        store.close();
        api.close();
      });
      final early = engine.calendar.date(2026, 10, 29, 0, 30);
      engine.saveEvent(
        CalendarEvent(
          id: 'early',
          title: 'Early',
          start: early,
          end: early.add(const Duration(minutes: 30)),
        ),
      );
      engine.saveEvent(
        CalendarEvent(
          id: 'all-day',
          title: 'All-day',
          start: DateTime(2026, 10, 29),
          end: DateTime(2026, 10, 30),
          allDay: true,
        ),
      );
      expect(engine.occurrencesOn(DateTime.utc(2026, 10, 28)), isEmpty);
      expect(engine.occurrencesOn(DateTime.utc(2026, 10, 30)), isEmpty);
      expect(
        engine
            .occurrencesOn(DateTime.utc(2026, 10, 29))
            .map((o) => o.event.id)
            .toSet(),
        {'early', 'all-day'},
      );
      final preview = buildDayPreview(engine, DateTime.utc(2026, 10, 29))!;
      expect(preview.lines.any((s) => s.contains('Early')), isTrue);
      expect(preview.lines.any((s) => s.contains('All-day')), isTrue);
      expect(
        buildWeekPlan(
          engine,
          DateTime.utc(2026, 10, 26),
        ).days[3].events.map((e) => e.title).toSet(),
        {'Early', 'All-day'},
      );
      expect(
        buildWeekPreview(engine, DateTime.utc(2026, 10, 26))!.lines,
        hasLength(2),
      );
      final nextYear = engine.calendar.date(2027, 1, 1, 0, 30);
      engine.saveEvent(
        CalendarEvent(
          id: 'next-year',
          title: 'New year',
          start: nextYear,
          end: nextYear.add(const Duration(minutes: 1)),
        ),
      );
      expect(yearReview(engine, 2026).events, 2);
      expect(yearReview(engine, 2027).events, 1);
    });
  }
  test(
    'a large native selection stays lazy and obeys the negotiated bound',
    () async {
      var opened = false;
      final file = await pickedFromSource(
        name: 'fixture.pdf',
        length: () async => 129 * 1024 * 1024,
        openRead: () {
          opened = true;
          return const Stream.empty();
        },
        maxBytes: 200 * 1024 * 1024,
      );
      expect(opened, isFalse);
      expect(file.bytes, isNull);
      expect(file.length, 129 * 1024 * 1024);
      await expectLater(
        pickedFromSource(
          name: 'too-large.pdf',
          length: () async => 201 * 1024 * 1024,
          openRead: () {
            opened = true;
            return const Stream.empty();
          },
          maxBytes: 200 * 1024 * 1024,
        ),
        throwsA(isA<ApiError>()),
      );
      expect(opened, isFalse);
    },
  );

  test('birthdays, holidays and DST days use the same civil windows', () async {
    final store = LocalStore.open(':memory:')
      ..setMeta('familyTimeZone', 'Europe/Berlin');
    final api = FamioApiClient('http://localhost');
    final engine = SyncEngine(store: store, api: api, memberId: 'member');
    addTearDown(() async {
      familyHolidayRegion = null;
      await engine.dispose();
      store.close();
      api.close();
    });
    engine.saveContact(
      const FamilyContact(
        id: 'birthday',
        name: 'Birthday',
        birthday: Birthday(10, 29),
      ),
    );
    familyHolidayRegion = GermanState.values.first;
    final birthday = engine
        .occurrencesOn(DateTime.utc(2026, 10, 29))
        .where((o) => isBirthdaySource(o.event.sourceId));
    expect(birthday, hasLength(1));
    expect(
      engine
          .occurrencesOn(DateTime.utc(2026, 10, 28))
          .where((o) => isBirthdaySource(o.event.sourceId)),
      isEmpty,
    );
    expect(
      engine
          .occurrencesOn(DateTime.utc(2027, 1, 1))
          .where((o) => isHolidaySource(o.event.sourceId)),
      hasLength(1),
    );
    store.setMeta('familyTimeZone', 'Pacific/Kiritimati');
    expect(
      engine
          .occurrencesOn(DateTime.utc(2027, 1, 1))
          .where((o) => isHolidaySource(o.event.sourceId)),
      hasLength(1),
    );
    store.setMeta('familyTimeZone', 'Europe/Berlin');
    final spring = engine.calendar.day(DateTime.utc(2027, 3, 28));
    final autumn = engine.calendar.day(DateTime.utc(2026, 10, 25));
    expect(engine.calendar.addDays(spring, 1).difference(spring).inHours, 23);
    expect(engine.calendar.addDays(autumn, 1).difference(autumn).inHours, 25);
    expect(engine.calendar.today(DateTime.utc(2026, 10, 28, 23, 30)).day, 29);
  });
}
