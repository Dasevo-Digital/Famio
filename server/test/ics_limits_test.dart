// Calendars from elsewhere cannot hold up the server (#395): sub-daily
// series and series that never fall on a day are shown once, long
// expansions stop, and whatever still takes too long is stopped in its own
// isolate.
import 'dart:async';
import 'dart:math';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/calendar/ics_import.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:rrule/rrule.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

String feed(String rule, {String start = '20261101T090000Z'}) => [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'BEGIN:VEVENT',
  'UID:x@test',
  'DTSTART:$start',
  'DTEND:${start.replaceFirst('T09', 'T10')}',
  'SUMMARY:Serie',
  'RRULE:$rule',
  'END:VEVENT',
  'END:VCALENDAR',
  '',
].join('\r\n');

void main() {
  late tz.Location berlin;
  setUpAll(() {
    FamioServerApp.initTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
  });
  final now = DateTime.utc(2026, 11, 11);
  List<CalendarEvent> read(String text) => importIcs(
    text,
    sourceId: 's',
    fallback: berlin,
    from: now.subtract(const Duration(days: 90)),
    to: now.add(const Duration(days: 400)),
  );

  test('more often than daily, or never on a day: shown once', () {
    final watch = Stopwatch()..start();
    for (final rule in [
      'FREQ=SECONDLY',
      'FREQ=MINUTELY',
      'FREQ=HOURLY;INTERVAL=2',
      'FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30',
      'FREQ=MONTHLY;BYMONTHDAY=31;BYMONTH=4,6,9,11',
      'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=31',
    ]) {
      final events = read(feed(rule));
      expect(events, hasLength(1), reason: rule);
      expect(events.single.start, DateTime.utc(2026, 11, 1, 9));
    }
    // Still repeated: a valid last day and a leap day.
    expect(read(feed('FREQ=MONTHLY;BYMONTHDAY=-1')).length, greaterThan(10));
    expect(
      importIcs(
        feed('FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29'),
        sourceId: 's',
        fallback: berlin,
        from: DateTime.utc(2027, 6),
        to: DateTime.utc(2028, 6),
      ).map((e) => e.start),
      [DateTime.utc(2028, 2, 29, 9)],
    );
    expect(watch.elapsedMilliseconds, lessThan(3000));
  });

  test('a yearly day without a month means every month', () {
    final events = read(
      feed('FREQ=YEARLY;BYMONTHDAY=30', start: '20260210T090000Z'),
    );
    expect(events.length, greaterThan(10));
  });

  test('series with an INTERVAL from long ago jump close to the window', () {
    final watch = Stopwatch()..start();
    final since1900 = read(
      feed('FREQ=DAILY;INTERVAL=2', start: '19000101T090000Z'),
    );
    expect(watch.elapsedMilliseconds, lessThan(2000));
    final first = DateTime.utc(1900, 1, 1, 9);
    expect(since1900, isNotEmpty);
    for (final e in since1900) {
      expect(e.start.difference(first).inDays % 2, 0);
    }
    // The same dates in the window as rrule from the very start.
    final random = Random(398);
    final window = (
      from: now.subtract(const Duration(days: 90)),
      to: now.add(const Duration(days: 400)),
    );
    for (var i = 0; i < 120; i++) {
      final frequency = ['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'][i % 4];
      final interval = 2 + random.nextInt(4);
      final day = 1 + random.nextInt(31);
      final month = 1 + random.nextInt(12);
      final year = 1995 + random.nextInt(25);
      final start = DateTime.utc(year, month, day, 9);
      if (start.day != day) continue;
      var rule = 'FREQ=$frequency;INTERVAL=$interval';
      if (frequency == 'WEEKLY' && random.nextBool()) {
        rule += ';BYDAY=MO,TH';
      }
      final stamp =
          '${start.year}${'${start.month}'.padLeft(2, '0')}'
          '${'${start.day}'.padLeft(2, '0')}T090000Z';
      final mine = [
        for (final e in importIcs(
          feed(rule, start: stamp),
          sourceId: 's',
          fallback: tz.UTC,
          from: window.from,
          to: window.to,
        ))
          e.start,
      ]..sort();
      final all = RecurrenceRule.fromString(
        'RRULE:$rule',
      ).getInstances(start: start, before: window.to);
      final expected = [
        for (final w in all)
          if (!w.add(const Duration(hours: 1)).isBefore(window.from) &&
              w.isBefore(window.to))
            w,
      ];
      expect(mine, expected, reason: '$rule from $start');
    }
  });

  test('a week starting on Sunday is read as well', () {
    final events = read(feed('FREQ=WEEKLY;WKST=SU;BYDAY=TU,TH'));
    expect(events.length, greaterThan(100));
  });

  test('a long expansion from the past stops, normal ones are complete', () {
    // Every second day since 1990: expanded from its start, within bounds.
    final second = read(
      feed('FREQ=DAILY;INTERVAL=2', start: '19900101T090000Z'),
    );
    expect(second.length, inInclusiveRange(240, 250));
    final watch = Stopwatch()..start();
    read(feed('FREQ=DAILY;COUNT=1000000', start: '19000101T090000Z'));
    expect(watch.elapsedMilliseconds, lessThan(3000));
    // A plain weekly series since 1950 jumps to the window by itself.
    expect(
      read(feed('FREQ=WEEKLY', start: '19500102T090000Z')).length,
      inInclusiveRange(69, 71),
    );
  });

  test('what still takes too long is stopped, the server goes on', () async {
    var ticks = 0;
    final ticker = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    addTearDown(ticker.cancel);
    final watch = Stopwatch()..start();
    // Work that never ends (rrule can look for the 10th Monday of each
    // month until the year 9999; how long that takes varies too much for
    // a test).
    await expectLater(
      runIsolated<int>(() {
        var n = 0;
        while (n >= 0) {
          n = (n + 1) % 1000;
        }
        return n;
      }, limit: const Duration(seconds: 1)),
      throwsA(isA<IcsTooComplex>()),
    );
    expect(watch.elapsedMilliseconds, lessThan(2500));
    expect(ticks, greaterThan(50), reason: 'the event loop kept running');
    // Normal calendars come back the same as without an isolate.
    final events = await importIcsIsolated(
      feed('FREQ=WEEKLY'),
      sourceId: 's',
      fallback: berlin,
      from: now.subtract(const Duration(days: 90)),
      to: now.add(const Duration(days: 400)),
    );
    expect(
      [for (final e in events) e.toData()],
      [for (final e in read(feed('FREQ=WEEKLY'))) e.toData()],
    );
    // Other errors do not show their internals.
    await expectLater(
      runIsolated(() => throw StateError('intern')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Die Kalenderdatei konnte nicht gelesen werden',
        ),
      ),
    );
    await expectLater(
      runIsolated(() => throw const FormatException('kaputt')),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'kaputt'),
      ),
    );
  });
}
