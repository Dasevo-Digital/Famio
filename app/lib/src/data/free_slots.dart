import 'package:famio_client/famio_client.dart';

/// A free time for everyone asked.
typedef FreeSlot = ({DateTime start, DateTime end});

/// When [memberIds] all have time for [length]: day by day from [from]
/// for [days] days, between [startHour] and [endHour]. Busy are the
/// appointments that involve any of them (one without people is for the
/// whole family), also as the one who brings or picks up. All-day entries
/// (birthdays, holidays, a trip) do not block a time. Each gap yields one
/// suggestion, at its start rounded up to the quarter hour; at most [max].
List<FreeSlot> freeSlots({
  required Iterable<Occurrence> occurrences,
  required Set<String> memberIds,
  required DateTime from,
  int days = 14,
  required Duration length,
  int startHour = 8,
  int endHour = 20,
  int max = 12,
}) {
  bool busyFor(CalendarEvent e) =>
      !e.allDay &&
      (e.memberIds.isEmpty ||
          memberIds.any(
            (m) => e.involves(m) || e.bringerId == m || e.pickerId == m,
          ));
  final busy = [
    for (final o in occurrences)
      if (busyFor(o.event)) (start: o.start, end: o.end),
  ]..sort((a, b) => a.start.compareTo(b.start));

  final slots = <FreeSlot>[];
  for (var d = 0; d < days && slots.length < max; d++) {
    // Calendar days: the clock change must not shift the window.
    var cursor = DateTime(from.year, from.month, from.day + d, startHour);
    final close = DateTime(from.year, from.month, from.day + d, endHour);
    if (cursor.isBefore(from)) cursor = _quarter(from);
    for (final b in busy) {
      if (!b.end.isAfter(cursor) || !b.start.isBefore(close)) continue;
      if (b.start.difference(cursor) >= length) {
        slots.add((start: cursor, end: cursor.add(length)));
        if (slots.length >= max) return slots;
      }
      if (b.end.isAfter(cursor)) cursor = _quarter(b.end);
    }
    if (close.difference(cursor) >= length) {
      slots.add((start: cursor, end: cursor.add(length)));
    }
  }
  return slots;
}

/// [t] rounded up to the next quarter hour.
DateTime _quarter(DateTime t) {
  final rest = t.minute % 15;
  final whole = rest == 0 && t.second == 0 && t.millisecond == 0;
  if (whole) return t;
  final base = DateTime(t.year, t.month, t.day, t.hour, t.minute - rest);
  return base.add(const Duration(minutes: 15));
}
