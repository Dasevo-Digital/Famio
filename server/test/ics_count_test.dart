// COUNT is turned into the last day of a series by arithmetic, not by
// expanding the series with rrule, which held up the server for minutes on
// long counts (#395). Compared against rrule for many short series.
import 'dart:math';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/calendar/event_ics.dart';
import 'package:rrule/rrule.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

String wrap(String body) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:x\r\n'
    '$body\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

String two(int v) => v.toString().padLeft(2, '0');

void main() {
  late tz.Location berlin;
  setUpAll(() {
    FamioServerApp.initTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
  });

  DateTime? until(DateTime start, String rule) {
    final stamp =
        '${start.year}${two(start.month)}${two(start.day)}T0930${two(0)}';
    final e = parseEventIcs(
      wrap(
        'DTSTART;TZID=Europe/Berlin:$stamp\r\n'
        'DTEND;TZID=Europe/Berlin:${stamp.replaceFirst('T09', 'T10')}\r\n'
        'RRULE:$rule',
      ),
      id: 'x',
      location: berlin,
    ).event;
    return e?.recurrence?.until;
  }

  test('the same last day as rrule', () {
    final random = Random(395);
    const days = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
    var compared = 0;
    for (var i = 0; i < 1500; i++) {
      final start = DateTime.utc(
        2020 + random.nextInt(10),
        1 + random.nextInt(12),
        // Often the end of a month.
        random.nextBool() ? 28 + random.nextInt(4) : 1 + random.nextInt(28),
        9,
        30,
      );
      if (start.day != DateTime.utc(start.year, start.month, start.day).day) {
        continue;
      }
      final frequency = [
        'DAILY',
        'WEEKLY',
        'MONTHLY',
        'YEARLY',
      ][random.nextInt(4)];
      final interval = 1 + random.nextInt(3);
      final count = 1 + random.nextInt(250);
      var rule = 'FREQ=$frequency;INTERVAL=$interval;COUNT=$count';
      if (frequency == 'WEEKLY' && random.nextBool()) {
        final picked = {
          for (var k = 0; k < 1 + random.nextInt(4); k++) random.nextInt(7),
        }.toList()..sort();
        rule += ';BYDAY=${[for (final d in picked) days[d]].join(',')}';
      }
      final mine = until(start, rule);
      if (mine == null) continue; // a rule Famio does not repeat
      final instances = RecurrenceRule.fromString(
        'RRULE:$rule',
      ).getInstances(start: start).toList();
      final last = instances.last;
      expect(
        mine,
        DateTime(last.year, last.month, last.day),
        reason: '$rule from $start',
      );
      compared++;
    }
    expect(compared, greaterThan(1000));
  });

  test('long counts are quick, absurd ones are refused', () {
    final watch = Stopwatch()..start();
    expect(
      until(DateTime.utc(2000, 1, 1), 'FREQ=DAILY;COUNT=100000'),
      DateTime(2273, 10, 15),
    );
    expect(
      until(DateTime.utc(2000, 1, 31), 'FREQ=MONTHLY;COUNT=50000'),
      isNotNull,
    );
    expect(until(DateTime.utc(2000, 1, 1), 'FREQ=DAILY;COUNT=100001'), isNull);
    expect(
      until(DateTime.utc(2000, 2, 29), 'FREQ=YEARLY;COUNT=99999'),
      isNull, // beyond the year 9999
    );
    expect(watch.elapsedMilliseconds, lessThan(2000));
    // Past the year 9999: not a series Famio keeps.
    expect(
      until(DateTime.utc(2000, 1, 1), 'FREQ=WEEKLY;INTERVAL=999;COUNT=99999'),
      isNull,
    );
  });

  test('a week starting on Sunday with an INTERVAL is not guessed', () {
    // Famio's weeks start on Monday; the first week would differ.
    expect(
      until(
        DateTime.utc(2026, 11, 2),
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU;COUNT=3',
      ),
      isNull,
    );
    // The day of the start, or every week: the same either way.
    expect(
      until(
        DateTime.utc(2026, 11, 2),
        'FREQ=WEEKLY;INTERVAL=2;WKST=SU;COUNT=3',
      ),
      DateTime(2026, 11, 30),
    );
  });
}
