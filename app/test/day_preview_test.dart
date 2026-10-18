import 'package:famio/src/data/day_preview.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/weather/weather.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  SyncEngine newEngine() => SyncEngine(
    store: LocalStore.open(':memory:'),
    api: FamioApiClient('localhost:1'),
    memberId: 'papa',
  );

  // The day of the clock change: 25 hours long.
  final day = DateTime(2026, 10, 25);

  test('my appointments, lifts, meal and due tasks; not the others\'', () {
    final engine = newEngine()
      ..saveEvent(
        CalendarEvent(
          id: 'a',
          title: 'Brunch',
          start: DateTime(2026, 10, 25, 10),
          end: DateTime(2026, 10, 25, 12),
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'b',
          title: 'Turnier',
          start: DateTime(2026, 10, 25, 14),
          end: DateTime(2026, 10, 25, 16),
          memberIds: const ['kind'],
          bringerId: 'papa',
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'c',
          title: 'Yoga Mama',
          start: DateTime(2026, 10, 25, 9),
          end: DateTime(2026, 10, 25, 10),
          memberIds: const ['mama'],
        ),
      )
      // The next day stays out, also across the extra hour.
      ..saveEvent(
        CalendarEvent(
          id: 'd',
          title: 'Montag',
          start: DateTime(2026, 10, 26, 0, 30),
          end: DateTime(2026, 10, 26, 1),
        ),
      )
      ..saveMeal(
        PlannedMeal(
          id: 'm',
          date: day,
          slot: MealSlot.dinner,
          title: 'Pfannkuchen',
        ),
      )
      ..saveTask(Task(id: 't1', title: 'Rasen mähen', due: day))
      ..saveTask(
        Task(id: 't2', title: 'Steuer', due: DateTime(2026, 10, 20)),
      )
      ..saveTask(
        Task(id: 't3', title: 'Nicht meins', due: day, assigneeIds: ['mama']),
      )
      ..saveTask(
        Task(id: 't4', title: 'Später', due: DateTime(2026, 10, 27)),
      );
    final p = buildDayPreview(engine, day)!;
    expect(p.title, 'Dein Tag · 2 Termine');
    expect(p.lines, [
      '10:00 Brunch',
      '14:00 🚗 bringen: Turnier',
      '🍽 Essen: Pfannkuchen',
      '2 Aufgaben fällig: Rasen mähen, Steuer',
    ]);
  });

  test('a free day sends nothing; the weather comes first', () {
    final engine = newEngine();
    expect(buildDayPreview(engine, day), isNull);
    engine.saveTask(Task(id: 't', title: 'Blumen gießen', due: day));
    final weather = WeatherForecast(
      fetched: DateTime(2026, 10, 24, 22),
      now: WeatherHour(
        time: DateTime(2026, 10, 24, 22),
        temperature: 9,
        apparent: 8,
        code: 2,
      ),
      hours: [
        for (var h = 0; h < 24; h++)
          WeatherHour(
            time: DateTime(2026, 10, 25, h),
            temperature: 6.0 + h ~/ 2,
            apparent: 6,
            code: h == 13 ? 61 : 2,
            precipitationProbability: h == 15 ? 70 : 10,
          ),
      ],
    );
    final p = buildDayPreview(engine, day, weather: weather)!;
    expect(p.lines.first, '🌧️ Regen, 9–16 °C, Regen 70 %');
  });

  test('every morning at the chosen time within the window', () {
    final times = dayPreviewTimes(
      DateTime(2026, 10, 24, 8),
      DateTime(2026, 10, 27),
      7 * 60 + 30,
    ).toList();
    expect(times.map((t) => t.$1), [
      DateTime(2026, 10, 25, 7, 30),
      DateTime(2026, 10, 26, 7, 30),
    ]);
  });
}
