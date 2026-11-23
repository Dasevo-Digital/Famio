import 'package:famio_client/famio_client.dart';

import '../l10n.dart';

/// The family's federal state or canton for public holidays (server
/// setting, kept for offline use by the app state); null: no holidays in
/// the calendar.
HolidayRegion? familyHolidayRegion;

/// Public holidays and, in Austria, school holidays: read-only and kept
/// out of what the family plans (no school bag on those days).
bool isHolidaySource(String? sourceId) =>
    sourceId?.startsWith('holiday:') ?? false;

/// Austrian school holidays, a part of [isHolidaySource].
bool isSchoolHolidaySource(String? sourceId) =>
    sourceId?.startsWith('holiday:school:') ?? false;

/// Public holidays overlapping `[from, to)` as read-only all-day events;
/// in Austria with the state's school holidays (Schulzeitgesetz).
List<CalendarEvent> holidayEvents(DateTime from, DateTime to) {
  final region = familyHolidayRegion;
  if (region == null) return const [];
  final first = DateTime.utc(from.year, from.month, from.day);
  final end = DateTime.utc(
    to.year,
    to.month,
    to.day,
    to.hour == 0 &&
            to.minute == 0 &&
            to.second == 0 &&
            to.millisecond == 0 &&
            to.microsecond == 0
        ? 0
        : 24,
  );
  return [
    for (var year = from.year; year <= to.year; year++)
      for (final h in region.holidays(year))
        if (!DateTime.utc(
              h.date.year,
              h.date.month,
              h.date.day,
            ).isBefore(first) &&
            DateTime.utc(h.date.year, h.date.month, h.date.day).isBefore(end))
          CalendarEvent(
            id: 'holiday:${region.code}:${h.date.toIso8601String().substring(0, 10)}',
            title: h.name,
            start: h.date,
            end: DateTime(h.date.year, h.date.month, h.date.day + 1),
            allDay: true,
            sourceId: 'holiday:${region.code}',
            notes: tr.holidayStatutoryIn(region.label),
          ),
    if (region case final AustrianState state)
      // Christmas holidays start the year before.
      for (var year = from.year - 1; year <= to.year; year++)
        for (final p in austrianSchoolHolidays(year, state))
          if (!DateTime.utc(
                p.last.year,
                p.last.month,
                p.last.day,
              ).isBefore(first) &&
              DateTime.utc(
                p.first.year,
                p.first.month,
                p.first.day,
              ).isBefore(end))
            CalendarEvent(
              id: 'holiday:school:${state.code}:${p.first.toIso8601String().substring(0, 10)}',
              title: p.title,
              start: p.first,
              end: DateTime(p.last.year, p.last.month, p.last.day + 1),
              allDay: true,
              sourceId: 'holiday:school:${state.code}',
              notes: tr.holidaySchoolIn(state.label),
            ),
  ];
}
