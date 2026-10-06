/// Finds appointments in German free text (a letter from school, an
/// invitation, an e-mail): dates like "12.10.", "12.10.2026", "12. Oktober",
/// ranges like "12.–16.10." or "vom 12. bis 16. Oktober", and times like
/// "14:30 Uhr", "um 9 Uhr" or "8–12 Uhr". The title is what is left of the
/// line, else the line before. Everything stays on the device.
library;

class EventSuggestion {
  const EventSuggestion({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.line,
  });

  final String title;
  final DateTime start;

  /// Exclusive for all-day suggestions (the day after the last day).
  final DateTime end;
  final bool allDay;

  /// The text line it came from, to show next to the suggestion.
  final String line;
}

const _months = {
  'januar': 1,
  'jan': 1,
  'jänner': 1,
  'februar': 2,
  'feb': 2,
  'märz': 3,
  'maerz': 3,
  'mär': 3,
  'mrz': 3,
  'april': 4,
  'apr': 4,
  'mai': 5,
  'juni': 6,
  'jun': 6,
  'juli': 7,
  'jul': 7,
  'august': 8,
  'aug': 8,
  'september': 9,
  'sept': 9,
  'sep': 9,
  'oktober': 10,
  'okt': 10,
  'november': 11,
  'nov': 11,
  'dezember': 12,
  'dez': 12,
};

final _monthWords =
    (_months.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join(
      '|',
    );

/// "12.10.2026", "12.10.26", "12.10." with an optional range start
/// ("12.–16.10.", "12. bis 16.10.").
final _numeric = RegExp(
  r'(?<!\d)(?:(\d{1,2})\.?\s*(?:-|–|—|bis)\s*)?(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?!\d)',
);

/// "12. Oktober 2026", "vom 12. bis 16. Okt.".
final _named = RegExp(
  '(?<!\\d)(?:(\\d{1,2})\\.?\\s*(?:-|–|—|bis)\\s*)?(\\d{1,2})\\.\\s*($_monthWords)\\.?(?:\\s+(\\d{4}))?',
  caseSensitive: false,
);

/// "14:30", "14.30 Uhr", "9 Uhr", with an optional end ("8–12 Uhr",
/// "von 8:00 bis 12:30").
final _time = RegExp(
  r'(?<![\d.])(\d{1,2})(?:[:.](\d{2}))?\s*(?:Uhr)?\s*(?:-|–|—|bis)\s*(\d{1,2})(?:[:.](\d{2}))?\s*Uhr'
  r'|(?<![\d.])(\d{1,2})[:.](\d{2})(?:\s*Uhr)?(?:\s*(?:-|–|—|bis)\s*(\d{1,2})[:.](\d{2}))?'
  r'|(?<![\d.])(\d{1,2})\s*Uhr',
  caseSensitive: false,
);

final _weekday = RegExp(
  r'\b(Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag|Mo|Di|Mi|Do|Fr|Sa|So)\b\.?,?',
  caseSensitive: false,
);

List<EventSuggestion> extractEvents(String text, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
  final found = <EventSuggestion>[];
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    for (final date in _dates(line, today)) {
      final time =
          _firstTime(line.substring(date.endIndex)) ??
          _firstTime(line.substring(0, date.startIndex));
      final title = _title(line, i > 0 ? lines[i - 1] : '');
      final DateTime start;
      final DateTime end;
      final bool allDay;
      if (time != null && date.lastDay == null) {
        start = DateTime(
          date.day.year,
          date.day.month,
          date.day.day,
          time.$1,
          time.$2,
        );
        end = time.$3 == null
            ? start.add(const Duration(hours: 1))
            : DateTime(
                date.day.year,
                date.day.month,
                date.day.day,
                time.$3!,
                time.$4!,
              );
        allDay = false;
      } else {
        start = date.day;
        final last = date.lastDay ?? date.day;
        end = DateTime(last.year, last.month, last.day + 1);
        allDay = true;
      }
      if (!end.isAfter(start)) continue;
      final key = '${start.toIso8601String()}|$title';
      if (!seen.add(key)) continue;
      found.add(
        EventSuggestion(
          title: title,
          start: start,
          end: end,
          allDay: allDay,
          line: line,
        ),
      );
    }
  }
  found.sort((a, b) => a.start.compareTo(b.start));
  return found;
}

typedef _Date = ({
  DateTime day,
  DateTime? lastDay,
  int startIndex,
  int endIndex,
});

Iterable<_Date> _dates(String line, DateTime today) sync* {
  final taken = <(int, int)>[];
  bool overlaps(Match m) => taken.any((t) => m.start < t.$2 && m.end > t.$1);
  for (final m in _named.allMatches(line)) {
    final month = _months[m[3]!.toLowerCase()];
    if (month == null) continue;
    final date = _build(
      int.parse(m[2]!),
      month,
      m[4],
      m[1],
      today,
      m.start,
      m.end,
    );
    if (date == null) continue;
    taken.add((m.start, m.end));
    yield date;
  }
  for (final m in _numeric.allMatches(line)) {
    if (overlaps(m)) continue;
    // "12.30 Uhr" is a time, not the 12th of a 30th month.
    final after = line.substring(m.end).trimLeft().toLowerCase();
    if (m[4] == null && after.startsWith('uhr')) continue;
    final date = _build(
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4],
      m[1],
      today,
      m.start,
      m.end,
    );
    if (date != null) yield date;
  }
}

_Date? _build(
  int day,
  int month,
  String? yearText,
  String? fromDay,
  DateTime today,
  int start,
  int end,
) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  int year;
  if (yearText != null) {
    year = int.parse(yearText);
    if (year < 100) year += 2000;
  } else {
    // Without a year: the next such day, a few weeks back still counts
    // (a letter about an event that just passed is rare).
    year = today.year;
    if (DateTime(
      year,
      month,
      day,
    ).isBefore(DateTime(today.year, today.month, today.day - 30))) {
      year++;
    }
  }
  final last = DateTime(year, month, day);
  if (last.month != month) return null; // 31.2.
  if (fromDay == null) {
    return (day: last, lastDay: null, startIndex: start, endIndex: end);
  }
  final first = int.parse(fromDay);
  if (first < 1 || first >= day) return null;
  return (
    day: DateTime(year, month, first),
    lastDay: last,
    startIndex: start,
    endIndex: end,
  );
}

/// (hour, minute, end hour?, end minute?) of the first time in [text].
(int, int, int?, int?)? _firstTime(String text) {
  for (final m in _time.allMatches(text)) {
    int? n(int g) => m[g] == null ? null : int.parse(m[g]!);
    (int, int, int?, int?) result;
    if (m[1] != null) {
      result = (n(1)!, n(2) ?? 0, n(3), n(4) ?? 0);
    } else if (m[5] != null) {
      result = (n(5)!, n(6)!, n(7), n(8));
    } else {
      result = (n(9)!, 0, null, null);
    }
    if (result.$1 > 23 || result.$2 > 59) continue;
    if (result.$3 != null && (result.$3! > 23 || (result.$4 ?? 0) > 59)) {
      result = (result.$1, result.$2, null, null);
    }
    return result;
  }
  return null;
}

String _title(String line, String previous) {
  var t = line
      .replaceAll(_named, ' ')
      .replaceAll(_numeric, ' ')
      .replaceAll(_time, ' ')
      .replaceAll(_weekday, ' ')
      .replaceAll(
        RegExp(
          r'\b(am|um|vom|von|bis|ab|den|ganztägig)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'[\s,;:–—\-|•*]+'), ' ')
      .trim();
  if (t.length < 3) {
    t = previous.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  if (t.isEmpty) t = 'Termin';
  return t.length > 60 ? '${t.substring(0, 57)}…' : t;
}
