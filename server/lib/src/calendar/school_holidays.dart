import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';

/// A state's school holiday feed with the official KMK dates where they
/// exist: the feed's events of those school years go, the official ones
/// come in their place, and days the feed lacks later are added. Only what
/// falls into the import window [from]–[to].
List<CalendarEvent> withOfficialSchoolHolidays(
  GermanState state,
  List<CalendarEvent> events, {
  required String sourceId,
  required DateTime from,
  required DateTime to,
}) {
  final official = officialSchoolHolidays[state] ?? const <SchoolHoliday>[];
  final additions = schoolHolidayAdditions[state] ?? const <SchoolHoliday>[];
  if (official.isEmpty && additions.isEmpty) return events;
  // From the state's first official period on: before it lie the summer
  // holidays of the school year before, which in Bavaria and
  // Baden-Württemberg run into August and September.
  final start = official.isEmpty
      ? officialSchoolHolidaysFrom
      : official.map((h) => h.first).reduce((a, b) => a.isBefore(b) ? a : b);
  final until = official.isEmpty
      ? start
      : official.map((h) => h.end).reduce((a, b) => a.isAfter(b) ? a : b);
  bool overlapsOfficial(CalendarEvent e) =>
      official.any((h) => e.start.isBefore(h.end) && e.end.isAfter(h.first));
  bool replaced(CalendarEvent e) =>
      (!e.start.isBefore(start) && e.start.isBefore(until)) ||
      overlapsOfficial(e);
  bool inWindow(SchoolHoliday h) => h.end.isAfter(from) && h.first.isBefore(to);
  CalendarEvent event(SchoolHoliday h) => CalendarEvent(
    id: sha1
        .convert(utf8.encode('$sourceId|kmk|${h.first.toIso8601String()}'))
        .toString()
        .substring(0, 32),
    title: '${h.kind.title} ${state.germanName} ${h.first.year}',
    start: h.first,
    end: h.end,
    allDay: true,
    sourceId: sourceId,
  );
  final result = [
    for (final e in events)
      if (!replaced(e)) e,
    for (final h in official)
      if (inWindow(h)) event(h),
  ];
  for (final h in additions) {
    final covered = result.any(
      (e) => e.allDay && !e.start.isAfter(h.first) && e.end.isAfter(h.first),
    );
    if (!covered && inWindow(h)) result.add(event(h));
  }
  return result..sort((a, b) => a.start.compareTo(b.start));
}
