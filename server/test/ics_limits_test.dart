// Calendars from elsewhere cannot hold up the server (#395): sub-daily
// series and series that never fall on a day are shown once, long
// expansions stop, and whatever still takes too long is stopped in its own
// isolate.
import 'dart:async';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/calendar/ics_import.dart';
import 'package:famio_shared/famio_shared.dart';
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

  test('a long expansion from the past stops, normal ones are complete', () {
    // Every second day since 1990: expanded from its start, within bounds.
    final second = read(
      feed('FREQ=DAILY;INTERVAL=2', start: '19900101T090000Z'),
    );
    expect(second.length, inInclusiveRange(240, 250));
    final watch = Stopwatch()..start();
    // Every second day since 1900 would need far more steps: stops quickly.
    read(feed('FREQ=DAILY;INTERVAL=2', start: '19000101T090000Z'));
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
    // rrule looks for the 10th Monday of each month until the year 9999.
    await expectLater(
      importIcsIsolated(
        feed('FREQ=MONTHLY;BYDAY=MO;BYSETPOS=10'),
        sourceId: 's',
        fallback: berlin,
        from: now,
        to: now.add(const Duration(days: 400)),
        limit: const Duration(seconds: 1),
      ),
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
    await expectLater(
      runIsolated(() => throw const FormatException('kaputt')),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'kaputt'),
      ),
    );
  });
}
