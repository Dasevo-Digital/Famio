import 'package:famio_client/famio_client.dart';

/// The family's federal state for public holidays (server setting, kept
/// for offline use by the app state); null: no holidays in the calendar.
GermanState? familyHolidayRegion;

bool isHolidaySource(String? sourceId) =>
    sourceId?.startsWith('holiday:') ?? false;

/// Public holidays overlapping `[from, to)` as read-only all-day events.
List<CalendarEvent> holidayEvents(DateTime from, DateTime to) {
  final state = familyHolidayRegion;
  if (state == null) return const [];
  return [
    for (var year = from.year; year <= to.year; year++)
      for (final h in germanHolidays(year, state))
        if (!h.date.isBefore(DateTime(from.year, from.month, from.day)) &&
            h.date.isBefore(to))
          CalendarEvent(
            id: 'holiday:${state.code}:${h.date.toIso8601String().substring(0, 10)}',
            title: h.name,
            start: h.date,
            end: DateTime(h.date.year, h.date.month, h.date.day + 1),
            allDay: true,
            sourceId: 'holiday:${state.code}',
            notes: 'Gesetzlicher Feiertag in ${state.label}',
          ),
  ];
}
