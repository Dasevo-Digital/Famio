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
  final start = officialSchoolHolidaysFrom;
  final until = official.isEmpty
      ? start
      : official.map((h) => h.end).reduce((a, b) => a.isAfter(b) ? a : b);
  bool replaced(CalendarEvent e) =>
      !e.start.isBefore(start) && e.start.isBefore(until);
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
