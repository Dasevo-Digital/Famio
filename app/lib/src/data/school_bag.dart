import 'package:famio_client/famio_client.dart';

import '../l10n.dart';
import 'family_data.dart';
import 'family_extras.dart';
import 'holidays.dart';

/// What a child needs at school on one day: the subjects, what to bring
/// for them and the family's appointments that name the child
/// ("Wandertag Mia").
class SchoolBag {
  const SchoolBag({
    required this.subjects,
    this.bring = const [],
    this.events = const [],
  });

  final List<String> subjects;
  final List<String> bring;
  final List<String> events;

  /// "Mathe, Deutsch, Sport · Mitnehmen: Sportzeug · Wandertag Mia".
  String get summary => [
    subjects.join(', '),
    if (bring.isNotEmpty) tr.schoolBagBring(bring.join(', ')),
    ...events,
  ].join(' · ');
}

/// [child]'s school bag for [day] (local midnight); null without lessons
/// that weekday, on public holidays and on the family's holidays.
SchoolBag? schoolBag(SyncEngine engine, Child child, DateTime day) {
  final t = engine.timetable(child.id);
  if (t == null || day.weekday > DateTime.friday) return null;
  final subjects = {for (final l in t.day(day.weekday)) l.subject}.toList();
  final end = DateTime(day.year, day.month, day.day + 1);
  if (subjects.isEmpty ||
      engine.holidayOn(day) != null ||
      holidayEvents(day, end).isNotEmpty) {
    return null;
  }
  final name = child.name.trim();
  final named = RegExp(
    '(^|[^\\p{L}])${RegExp.escape(name)}(\$|[^\\p{L}])',
    caseSensitive: false,
    unicode: true,
  );
  return SchoolBag(
    subjects: subjects,
    bring: t.bringOn(day.weekday),
    events: [
      for (final o in engine.occurrencesForDays(day, end))
        if (name.isNotEmpty &&
            !o.start.isBefore(engine.calendar.day(day)) &&
            named.hasMatch(o.event.title))
          o.event.title,
    ],
  );
}

/// "18:30" as hour and minute; null if it is none.
(int, int)? parseClock(String? time) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time ?? '');
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  return h < 24 && min < 60 ? (h, min) : null;
}
