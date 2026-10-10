/// Finds appointments in free text (a letter from school, an invitation, an
/// e-mail) in German, English and Spanish:
///
/// - dates like "12.10.", "12.10.2026", "12. Oktober", "October 12, 2026",
///   "12th October", "12 de octubre", "10/12/2026", "2026-10-12";
/// - ranges like "12.–16.10.", "vom 12. bis 16. Oktober", "October 19 to
///   30", "del 19 al 30 de octubre";
/// - times like "14:30 Uhr", "um 9 Uhr", "8–12 Uhr", "2:30 pm",
///   "10 am – 12 pm", "18:00 h", "de 8 a 12 h", "a las 9 de la mañana".
///
/// What is ambiguous ("10/12/2026", a bare "am" after a number) follows the
/// language the text is written in, else the app's. The title is what is
/// left of the line, else the line before. Everything stays on the device.
library;

import '../l10n.dart';

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
  // German
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
  // English
  'january': 1,
  'february': 2,
  'march': 3,
  'mar': 3,
  'may': 5,
  'june': 6,
  'july': 7,
  'october': 10,
  'oct': 10,
  'december': 12,
  'dec': 12,
  // Spanish
  'enero': 1,
  'ene': 1,
  'febrero': 2,
  'marzo': 3,
  'abril': 4,
  'abr': 4,
  'mayo': 5,
  'junio': 6,
  'julio': 7,
  'agosto': 8,
  'ago': 8,
  'septiembre': 9,
  'setiembre': 9,
  'octubre': 10,
  'noviembre': 11,
  'diciembre': 12,
  'dic': 12,
};

final _monthWords =
    (_months.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join(
      '|',
    );

/// Joins the two ends of a range: "12.–16.", "12 bis 16", "19 to 30",
/// "del 19 al 30".
const _to = r'(?:-|–|—|bis|to|through|until|till|al|a)';

/// "12.10.2026", "12.10.26", "12.10." with an optional range start
/// ("12.–16.10.", "12. bis 16.10.").
final _numeric = RegExp(
  r'(?<!\d)(?:(\d{1,2})\.?\s*(?:-|–|—|bis)\s*)?(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?!\d)',
);

/// "10/12/2026" (day or month first, see [extractEvents]) and
/// "2026-10-12". Without a year only after "on", "el" and the like ("on
/// 10/16", "el 16/10"): "1/2" alone is rather half of something.
final _slashed = RegExp(
  r'(?<![\d/])(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})(?![\d/])'
  r'|(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)'
  r'|(?<=\b(?:on|the|from|to|until|el|del|al|desde|hasta)\s+)(\d{1,2})/(\d{1,2})(?![\d/])',
  caseSensitive: false,
);

/// Day first: "12. Oktober 2026", "vom 12. bis 16. Okt.", "12th of
/// October", "12 de octubre de 2026", "del 19 al 30 de octubre".
final _named = RegExp(
  '(?<!\\d)(?:(\\d{1,2})(?:\\.|st|nd|rd|th)?\\s*$_to\\s*)?'
  '(\\d{1,2})(?:\\.|st|nd|rd|th)?\\s*(?:de\\s+|of\\s+)?'
  '($_monthWords)\\.?(?![a-zäöüß])(?:,?\\s*(?:de\\s+)?(\\d{4}))?',
  caseSensitive: false,
);

/// Month first: "October 12, 2026", "Oct. 12th", "October 19 to 30".
final _monthFirst = RegExp(
  '(?<![a-zäöüß])($_monthWords)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?![\\d:.]\\d|\\d)'
  '(?:\\s*$_to\\s*(\\d{1,2})(?:st|nd|rd|th)?(?!\\d))?(?:,?\\s*(\\d{4}))?',
  caseSensitive: false,
);

/// The units after an hour: "Uhr", Spanish "h" or "horas".
const _unit = r'(?:Uhr|h\b|hrs?\b|horas?\b)';

/// "2:30 pm", "10 am – 12 pm", "5:30 - 7 pm".
final _meridiem = RegExp(
  r'(?<![\d.:])(\d{1,2})(?:[:.](\d{2}))?\s*(?:([ap])\.?\s?m\b\.?)?'
  r'\s*(?:-|–|—|to|until|till)\s*(\d{1,2})(?:[:.](\d{2}))?\s*([ap])\.?\s?m\b\.?'
  r'|(?<![\d.:])(\d{1,2})(?:[:.](\d{2}))?\s*([ap])\.?\s?m\b\.?',
  caseSensitive: false,
);

/// "8–12 Uhr", "de 8 a 12 h", "14:30", "14.30 Uhr", "von 8:00 bis 12:30",
/// "9 Uhr", "18 h".
final _time = RegExp(
  '(?<![\\d.])(\\d{1,2})(?:[:.](\\d{2}))?\\s*$_unit?\\s*$_to\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*$_unit'
  '|(?<![\\d.])(\\d{1,2})[:.](\\d{2})(?!\\.)(?:\\s*$_unit)?(?:\\s*$_to\\s*(\\d{1,2})[:.](\\d{2})(?!\\.))?'
  '|(?<![\\d.])(\\d{1,2})\\s*$_unit',
  caseSensitive: false,
);

/// Spanish "a las 6 de la tarde".
final _aLas = RegExp(
  '\\ba las (\\d{1,2})(?:[:.](\\d{2}))?(?:\\s*$_unit)?'
  '(?:\\s*(?:de|por) la (mañana|tarde|noche))?',
  caseSensitive: false,
);

final _weekday = RegExp(
  r'(?<![a-zäöüßáéíóúñ])(?:montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag'
  r'|monday|tuesday|wednesday|thursday|friday|saturday|sunday'
  r'|lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo)'
  r'(?![a-zäöüßáéíóúñ])\.?,?',
  caseSensitive: false,
);

/// "Fr, 16.10.", "Mo. 3.11.", "Fri, Oct 16": short weekdays only before
/// a date, so "to do" stays in a title.
final _shortWeekday = RegExp(
  r'(?<![A-Za-zäöüß])(?:Mo|Di|Mi|Do|Fr|Sa|So|Mon|Tue|Tues|Wed|Thu|Thurs|Fri|Sat|Sun)'
  r'(?:\.,?|,|(?=\s+\d))',
);

/// Small words left around a title once the date is gone.
const _fillers = {
  'on',
  'at',
  'from',
  'to',
  'until',
  'the',
  'of',
  'and',
  'el',
  'la',
  'las',
  'los',
  'del',
  'al',
  'de',
  'desde',
  'hasta',
  'a',
  'y',
  'und',
};

/// The language [text] is most likely written in (de, en or es), else
/// [fallback]: by small words every letter uses.
String guessLanguage(String text, {required String fallback}) {
  const words = {
    'de': {
      'der',
      'die',
      'das',
      'und',
      'uhr',
      'am',
      'um',
      'vom',
      'bis',
      'mit',
      'für',
      'ist',
      'findet',
      'statt',
      'liebe',
      'wir',
      'ihr',
      'eltern',
    },
    'en': {
      'the',
      'and',
      'at',
      'on',
      'from',
      'with',
      'for',
      'is',
      'will',
      'be',
      'dear',
      'we',
      'you',
      'parents',
      'pm',
    },
    'es': {
      'el',
      'la',
      'los',
      'las',
      'del',
      'y',
      'con',
      'para',
      'es',
      'será',
      'queridos',
      'queridas',
      'padres',
      'familias',
      'horas',
      'nos',
    },
  };
  final counts = {for (final l in words.keys) l: 0};
  for (final w in text.toLowerCase().split(RegExp(r'[^a-zäöüßáéíóúñ]+'))) {
    for (final MapEntry(key: l, value: set) in words.entries) {
      if (set.contains(w)) counts[l] = counts[l]! + 1;
    }
  }
  final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
  final tie = counts.values.where((c) => c == best.value).length > 1;
  return best.value == 0 || tie ? fallback : best.key;
}

List<EventSuggestion> extractEvents(
  String text, {
  DateTime? now,
  String? language,
}) {
  final today = now ?? DateTime.now();
  final lang = language ?? guessLanguage(text, fallback: appLanguage);
  final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
  final found = <EventSuggestion>[];
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    for (final date in _dates(line, today, lang)) {
      final time =
          _firstTime(line.substring(date.endIndex), lang) ??
          _firstTime(line.substring(0, date.startIndex), lang);
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

Iterable<_Date> _dates(String line, DateTime today, String lang) sync* {
  final taken = <(int, int)>[];
  bool overlaps(Match m) => taken.any((t) => m.start < t.$2 && m.end > t.$1);
  _Date? take(Match m, _Date? date) {
    if (date != null) taken.add((m.start, m.end));
    return date;
  }

  for (final m in _named.allMatches(line)) {
    final month = _months[m[3]!.toLowerCase()];
    if (month == null) continue;
    final date = take(
      m,
      _build(int.parse(m[2]!), month, m[4], m[1], today, m.start, m.end),
    );
    if (date != null) yield date;
  }
  for (final m in _monthFirst.allMatches(line)) {
    if (overlaps(m)) continue;
    final month = _months[m[1]!.toLowerCase()];
    if (month == null) continue;
    final last = m[3] ?? m[2]!;
    final date = take(
      m,
      _build(
        int.parse(last),
        month,
        m[4],
        m[3] == null ? null : m[2],
        today,
        m.start,
        m.end,
      ),
    );
    if (date != null) yield date;
  }
  for (final m in _slashed.allMatches(line)) {
    if (overlaps(m)) continue;
    final _Date? date;
    if (m[4] != null) {
      date = _build(
        int.parse(m[6]!),
        int.parse(m[5]!),
        m[4],
        null,
        today,
        m.start,
        m.end,
      );
    } else {
      final year = m[1] != null;
      var (day, month) = (
        int.parse(m[year ? 1 : 7]!),
        int.parse(m[year ? 2 : 8]!),
      );
      // English writes the month first; a number above 12 settles it.
      if ((lang == 'en' && day <= 12) || month > 12) {
        (day, month) = (month, day);
      }
      date = _build(day, month, m[3], null, today, m.start, m.end);
    }
    if (take(m, date) case final d?) yield d;
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

typedef _Time = (int, int, int?, int?);

/// (hour, minute, end hour?, end minute?) of the first time in [text].
_Time? _firstTime(String text, String lang) {
  final candidates = <(int, _Time)>[];
  for (final m in _meridiem.allMatches(text)) {
    if (_twelveHour(m, lang) case final t?) candidates.add((m.start, t));
  }
  for (final m in _aLas.allMatches(text)) {
    var hour = int.parse(m[1]!);
    final part = m[3]?.toLowerCase();
    if ((part == 'tarde' || part == 'noche') && hour < 12) hour += 12;
    candidates.add((m.start, (hour, int.parse(m[2] ?? '0'), null, null)));
  }
  for (final m in _time.allMatches(text)) {
    int? n(int g) => m[g] == null ? null : int.parse(m[g]!);
    final _Time t;
    if (m[1] != null) {
      t = (n(1)!, n(2) ?? 0, n(3), n(4) ?? 0);
    } else if (m[5] != null) {
      t = (n(5)!, n(6)!, n(7), n(8));
    } else {
      t = (n(9)!, 0, null, null);
    }
    candidates.add((m.start, t));
  }
  candidates.sort((a, b) => a.$1.compareTo(b.$1));
  for (final (_, t) in candidates) {
    var result = t;
    if (result.$1 > 23 || result.$2 > 59) continue;
    if (result.$3 != null && (result.$3! > 23 || (result.$4 ?? 0) > 59)) {
      result = (result.$1, result.$2, null, null);
    }
    return result;
  }
  return null;
}

/// A time with am or pm in 24 hours. A bare lower case "am" only counts
/// in English text: in German "9 am Freitag" means something else.
_Time? _twelveHour(Match m, String lang) {
  final range = m[6] != null;
  final marks = range ? [m[3], m[6]] : [m[9]];
  final written = m[0]!;
  final plainAm = RegExp(r'\d\s*am\b').hasMatch(written);
  if (plainAm && lang != 'en') return null;
  int h(String hour, String? period) {
    final v = int.parse(hour) % 12;
    return period?.toLowerCase() == 'p' ? v + 12 : v;
  }

  if (int.parse(range ? m[1]! : m[7]!) > 12) return null;
  if (!range) return (h(m[7]!, m[9]), int.parse(m[8] ?? '0'), null, null);
  if (int.parse(m[4]!) > 12) return null;
  final endHour = h(m[4]!, marks[1]);
  var startHour = h(m[1]!, marks[0] ?? marks[1]);
  // "11 – 1 pm": the start without its own mark is in the morning.
  if (marks[0] == null && startHour >= endHour && startHour >= 12) {
    startHour -= 12;
  }
  return (startHour, int.parse(m[2] ?? '0'), endHour, int.parse(m[5] ?? '0'));
}

String _title(String line, String previous) {
  // Short weekdays first: they are only recognised before a date.
  var t = line
      .replaceAll(_shortWeekday, ' ')
      .replaceAll(_weekday, ' ')
      .replaceAll(_named, ' ')
      .replaceAll(_monthFirst, ' ')
      .replaceAll(_slashed, ' ')
      .replaceAll(_numeric, ' ')
      .replaceAll(_meridiem, ' ')
      .replaceAll(_aLas, ' ')
      .replaceAll(_time, ' ')
      .replaceAll(
        RegExp(
          r'\b(am|um|vom|von|bis|ab|den|ganztägig|all day|todo el día)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'[\s,;:–—\-|•*.]+$'), '')
      .replaceAll(RegExp(r'[\s,;:–—\-|•*]+'), ' ')
      .trim();
  // English and Spanish small words only at the edges: inside they belong
  // to the title ("Fiesta de otoño").
  var words = t.split(' ');
  while (words.isNotEmpty && _fillers.contains(words.first.toLowerCase())) {
    words = words.sublist(1);
  }
  while (words.isNotEmpty && _fillers.contains(words.last.toLowerCase())) {
    words = words.sublist(0, words.length - 1);
  }
  t = words.join(' ');
  if (t.length < 3) {
    t = previous.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  if (t.isEmpty) t = tr.commonEvent;
  return t.length > 60 ? '${t.substring(0, 57)}…' : t;
}
