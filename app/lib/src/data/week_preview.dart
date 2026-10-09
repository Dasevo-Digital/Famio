import 'package:famio_client/famio_client.dart';
import 'package:intl/intl.dart';

import 'family_data.dart';
import '../l10n.dart';

/// Sunday evening's look at the coming week for one member: their
/// appointments, the lifts they drive, birthdays and holidays.
class WeekPreview {
  const WeekPreview({required this.title, required this.lines});

  final String title;

  /// "Mo 19:00 Elternabend", at most [maxLines] plus "… und 3 weitere".
  final List<String> lines;

  static const maxLines = 8;

  String get body => lines.join('\n');
}

/// The preview of the week starting on [monday] (local midnight), or null
/// if nothing is planned for the member.
WeekPreview? buildWeekPreview(SyncEngine engine, DateTime monday) {
  final end = DateTime(monday.year, monday.month, monday.day + 7);
  final me = engine.memberId;
  final day = DateFormat.E(appLanguage);
  final time = DateFormat.jm(appLanguage);
  final items = [
    for (final o in engine.occurrences(monday, end))
      if (!o.start.isBefore(monday) &&
          (o.event.involves(me) ||
              o.event.bringerId == me ||
              o.event.pickerId == me))
        o,
  ];
  if (items.isEmpty) return null;
  final lines = [
    for (final o in items)
      [
        day.format(o.start).replaceAll('.', ''),
        if (!o.event.allDay) time.format(o.start),
        if (o.event.bringerId == me)
          '🚗 bringen: ${o.event.title}'
        else if (o.event.pickerId == me)
          '🚗 abholen: ${o.event.title}'
        else
          o.event.title,
      ].join(' '),
  ];
  final lifts = items
      .where((o) => o.event.bringerId == me || o.event.pickerId == me)
      .length;
  final shown = lines.length > WeekPreview.maxLines
      ? [
          ...lines.take(WeekPreview.maxLines - 1),
          '… und ${lines.length - WeekPreview.maxLines + 1} weitere',
        ]
      : lines;
  return WeekPreview(
    title: [
      'Deine Woche: ${items.length == 1 ? '1 Termin' : '${items.length} Termine'}',
      if (lifts > 0) lifts == 1 ? '1 Fahrt' : '$lifts Fahrten',
    ].join(' · '),
    lines: shown,
  );
}

/// Sundays at 18:00 within `[from, to)`, each with the Monday after it.
Iterable<(DateTime at, DateTime monday)> weekPreviewTimes(
  DateTime from,
  DateTime to,
) sync* {
  var sunday = DateTime(
    from.year,
    from.month,
    from.day + (DateTime.sunday - from.weekday) % 7,
    18,
  );
  for (
    ;
    sunday.isBefore(to);
    sunday = DateTime(sunday.year, sunday.month, sunday.day + 7, 18)
  ) {
    if (sunday.isBefore(from)) continue;
    yield (sunday, DateTime(sunday.year, sunday.month, sunday.day + 1));
  }
}
