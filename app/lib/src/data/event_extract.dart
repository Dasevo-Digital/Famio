// l10n-file: Wörter, nach denen der Termin-Leser sucht
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
    this.location = '',
  });

  final String title;
  final DateTime start;

  /// Exclusive for all-day suggestions (the day after the last day).
  final DateTime end;
  final bool allDay;

  /// The text line it came from, to show next to the suggestion.
  final String line;

  /// What a line like "Ort: Aula" says near the date.
  final String location;
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

/// Words that announce a date, so that the numbers after them are one.
const _announced =
    r'(?:\b(?:am|den|vom|bis|montag|dienstag|mittwoch|donnerstag|freitag'
    r'|samstag|sonntag|mo|di|mi|do|fr|sa|so)\.?|,)';

/// "13. 11. 2026", "13.11. 2026": printed letters and recognised text put
/// spaces into dates. Without a year only after [_announced], because "1. 2.
/// Klasse" is none.
final _spacedDate = RegExp(
  r'(?<![\d.])(\d{1,2})\.[ \t]*(\d{1,2})\.[ \t]*(\d{4})(?!\d)'
  '|(?<=$_announced[ \\t]+)(\\d{1,2})\\.[ \\t]+(\\d{1,2})\\.(?!\\d)',
  caseSensitive: false,
);

/// "Di 24.11": the last dot left out. Only after [_announced] and not before
/// "Uhr": "10.15" alone is a time.
final _bareDate = RegExp(
  '(?<=$_announced[ \\t]+)(\\d{1,2})\\.(\\d{1,2})(?![\\d.:]|[ \\t]*uhr)',
  caseSensitive: false,
);

/// A sentence broken just before its date: "… am Freitag, den" and then
/// "13. November …".
final _brokenBeforeDate = RegExp(
  r'(?:\b(?:am|den|vom)|\b(?:montag|dienstag|mittwoch|donnerstag|freitag'
  r'|samstag|sonntag),)$',
  caseSensitive: false,
);

/// A line that goes on with the time of the line before: "um 19:30 Uhr im
/// Raum 12".
final _startsWithTime = RegExp(
  r'^(?:(?:um|ab|gegen|von)\s+)?\d{1,2}(?:[:.]\d{2})?\s*uhr\b'
  r'|^(?:um|ab|gegen|von)\s+\d{1,2}[:.]\d{2}\b',
  caseSensitive: false,
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

/// What stands in front of the facts of an invitation: never its title.
const _labels = [
  // German
  'einlass',
  'datum', 'termin', 'wann', 'tag', 'zeit', 'uhrzeit', 'beginn', 'start',
  'ende', 'wo', 'ort', 'treffpunkt',
  // English
  'date', 'when', 'time', 'where', 'starts', 'venue', 'place',
  // Spanish
  'fecha', 'cuándo', 'cuando', 'hora', 'día', 'dia', 'dónde', 'donde',
  'lugar',
];

/// Labels that say what the event is, and where.
const _titleLabels =
    'was|veranstaltung|anlass|thema|betreff|titel|what|event|subject|qué'
    '|evento|asunto|título';
const _placeLabels = 'ort|wo|treffpunkt|where|venue|place|lugar|dónde|donde';

/// After a label: a colon the recognition may have read as another mark, or
/// the gap to the next column of a form.
const _afterLabel = r'(?:\s*[:.;]\s*|\s{2,})';

/// "Ort: Aula", also without its colon: a line that is no title.
final _labelled = RegExp(
  '^(?:${_labels.join('|')}|$_titleLabels)$_afterLabel'
  r'|^(?:ort|wo|was|wann|datum|uhrzeit)\s',
  caseSensitive: false,
);

/// "Was: Sommerfest", "Veranstaltung   Sommerfest", "Was Sommerfest".
final _titleLine = RegExp(
  '^(?:$_titleLabels)$_afterLabel(.+)\$|^was\\s+(.+)\$',
  caseSensitive: false,
);

/// "Ort: Aula", "Ort   Aula", "Ort Aula": where it takes place.
final _placeLine = RegExp(
  '^(?:$_placeLabels)$_afterLabel(.+)\$'
  r'|^(?:ort|wo)\s+(?!ist\b|sind\b)(.+)$',
  caseSensitive: false,
);

/// "Hauptstraße 12", "12345 Musterstadt".
final _address = RegExp(
  r'(?<!\d)\d{5}\s+\p{L}'
  r'|(?:straße|strasse|str\.|weg|allee|gasse|platz|ring|damm)\s*\d+',
  unicode: true,
  caseSensitive: false,
);

/// Phone, mail, web and bank details.
final _contact = RegExp(
  r'^(?:tel|telefon|fax|mobil|handy|e-?mail|www|web|iban|bic)\b'
  r'|https?://|\S@\S|(?<!\d)0\d{2,5}[ /-]?\d{4,}',
  caseSensitive: false,
);

final _greeting = RegExp(
  r'^(?:liebe|lieber|sehr geehrte|hallo|guten tag|dear|hello|hi\b|querid'
  r'|estimad|hola)',
  caseSensitive: false,
);

/// Words that tell a line is about an event ...
final _eventWord = RegExp(
  r'fest|feier|geburtstag|abend|umzug|basar|markt|ausflug|fahrt|treffen'
  r'|training|turnier|konzert|aufführung|vorstellung|sprechtag|sprechstunde'
  r'|versammlung|konferenz|kurs|party|einladung|termin|untersuchung|impfung'
  r'|praxis|\bdr\.|invitation|meeting|appointment|birthday|trip|outing'
  r'|festival|concert|recital|excursi|reunión|cita|cumpleaños|fiesta'
  r'|concierto',
  caseSensitive: false,
);

/// ... or a place, also when nothing labels it.
final _placeWord = RegExp(
  r'schule|kita|kindergarten|aula|halle|saal|zentrum|schulhof|klinik'
  r'|haus\b|heim\b|gasthof|gaststätte|restaurant|hotel|museum|bibliothek'
  r'|bücherei|schwimmbad|hallenbad|freibad|spielplatz|sportplatz|stadtpark'
  r'|kirche|stadion|school|hall\b|escuela|colegio|centro\b|sala\b',
  caseSensitive: false,
);

/// Whether [text] is about an event. Only what comes before "am", "im" … :
/// the "Festhalle am Markt" is no market. German compounds are what they end
/// in: a "Festhalle" is a hall, a "Kindergartenfest" a party.
bool _namesEvent(String text) => text
    .split(RegExp(r'\s(?:am|im|in|an|auf|at|en)\s', caseSensitive: false))
    .first
    .split(RegExp(r'[\s-]+'))
    .any((word) {
      int last(RegExp r) => r.allMatches(word).lastOrNull?.start ?? -1;
      return last(_eventWord) > last(_placeWord);
    });

/// "Ihr nächster Termin:" announces a date and says nothing about it.
final _justADate = RegExp(
  r'^(?:(?:ihr|ihre|dein|deine|unser|unsere|der|die|nächste[rns]?|neue[rns]?'
  r'|folgende[rns]?|your|our|next|new|the|su|tu|próxim[oa]|nuev[oa])\s+)*'
  r'(?:termin|termine|datum|appointment|date|event|cita|fecha|evento)$',
  caseSensitive: false,
);

/// A line that ends like a sentence tells something, it names nothing.
final _statement = RegExp(r'[.!?]\s*$');

/// "Auf dem Schulhof am 13.11." says where, not what.
final _placeStart = RegExp(
  r'^(?:im|in der|in dem|auf dem|auf der|an der|at the|en el|en la)\s',
  caseSensitive: false,
);

/// What ends a line of a sentence but no title: "findet statt", "ist".
final _trailingVerb = RegExp(
  r'(?:\s+(?:findet|finden|statt|ist|sind|beginnt|startet'
  r'|is|are|starts|será|serán|es|son))+$',
  caseSensitive: false,
);

/// The same at the start: "findet der Elternabend statt".
final _leadingVerb = RegExp(r'^(?:findet|finden)\s+', caseSensitive: false);

/// The first sentence when another follows. Short words before the dot are
/// rather abbreviations ("Dr. Muster").
final _firstSentence = RegExp(
  r'^(.*?[\p{L}\d]{4,})[.!?]\s+\p{Lu}',
  unicode: true,
);

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
  final lines = _lines(text);
  final found = <EventSuggestion>[];
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    for (final date in _dates(line, today, lang)) {
      final time =
          _firstTime(line.substring(date.endIndex), lang) ??
          _firstTime(line.substring(0, date.startIndex), lang) ??
          (date.lastDay == null ? _timeNearby(lines, i, today, lang) : null);
      final (:title, :place) = _titleAndPlace(lines, i, today, lang);
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
          location: place,
        ),
      );
    }
  }
  found.sort((a, b) => a.start.compareTo(b.start));
  return found;
}

/// [text] line by line, with dates as the patterns above expect them and
/// sentences broken before their date made whole.
List<String> _lines(String text) {
  final lines = <String>[];
  final repaired = text
      .replaceAllMapped(
        _spacedDate,
        (m) => '${m[1] ?? m[4]}.${m[2] ?? m[5]}.${m[3] ?? ''}',
      )
      .replaceAllMapped(
        _bareDate,
        (m) => int.parse(m[2]!) > 12 ? m[0]! : '${m[1]}.${m[2]}.',
      );
  for (final raw in repaired.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    final goesOn =
        lines.isNotEmpty &&
        _brokenBeforeDate.hasMatch(lines.last) &&
        line.startsWith(RegExp(r'\d{1,2}\.'));
    if (goesOn) {
      lines.last = '${lines.last} $line';
    } else {
      lines.add(line);
    }
  }
  return lines;
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

/// The time beside the date at [index] for letters and invitations with one
/// fact per line: up to two lines below, stopping at the next date, else the
/// line above.
_Time? _timeNearby(List<String> lines, int index, DateTime today, String lang) {
  var seen = 0;
  for (var i = index + 1; i < lines.length && seen < 2; i++) {
    if (lines[i].isEmpty) continue;
    if (_dates(lines[i], today, lang).isNotEmpty) break;
    seen++;
    if (_timeOfLine(lines[i], today, lang) case final time?) return time;
  }
  // Above only what no date before it claims.
  final above = _nextLines(lines, index, -1).take(3).toList();
  if (above.isEmpty) return null;
  final claimed = above.skip(1).any((l) => _dates(l, today, lang).isNotEmpty);
  return claimed ? null : _timeOfLine(above.first, today, lang);
}

/// The lines around [index] that say something, nearest first.
Iterable<String> _nextLines(List<String> lines, int index, int step) sync* {
  for (var i = index + step; i >= 0 && i < lines.length; i += step) {
    if (lines[i].isNotEmpty) yield lines[i];
  }
}

/// The time of a line that says little else: "Uhrzeit: 19:30 Uhr", "von 14
/// bis 17 Uhr", "10:15". A sentence that mentions an hour is about something
/// else ("bitte bis 12 Uhr anmelden").
_Time? _timeOfLine(String line, DateTime today, String lang) {
  if (_dates(line, today, lang).isNotEmpty) return null;
  final words = _clean(line).split(' ').where((w) => w.isNotEmpty);
  return words.length > 2 && !_startsWithTime.hasMatch(line)
      ? null
      : _firstTime(line, lang);
}

/// What the date at [index] is about and where. Most lines around a date
/// are something else: labels, addresses, phone numbers, a greeting. What is
/// said outright counts first, then the line of the date, then the nearest
/// line that names an event, above before below, then the nearest that is
/// no place. A place is never the title: without one the appointment is
/// just an appointment there. What stands between two dates belongs to the
/// first.
({String title, String place}) _titleAndPlace(
  List<String> lines,
  int index,
  DateTime today,
  String lang,
) {
  bool dated(String line) => _dates(line, today, lang).isNotEmpty;
  bool fits(String title) =>
      title.length >= 3 &&
      !_labels.contains(title.toLowerCase()) &&
      !_justADate.hasMatch(title);
  String titleIn(String line) => _sentence(_clean(line));
  String? value(RegExp label, String line) {
    final match = label.firstMatch(line);
    return (match?[1] ?? match?[2])?.trim();
  }

  bool plain(String line) =>
      !_labelled.hasMatch(line) &&
      !_address.hasMatch(line) &&
      !_contact.hasMatch(line) &&
      !_greeting.hasMatch(line);
  bool place(String title) =>
      !_namesEvent(title) &&
      (_placeWord.hasMatch(title) || _placeStart.hasMatch(title));

  final up = _nextLines(lines, index, -1).toList();
  final above = up.takeWhile((l) => !dated(l)).take(5).toList();
  final below = _nextLines(
    lines,
    index,
    1,
  ).takeWhile((l) => !dated(l)).take(4).toList();
  final around = [...below, if (!up.any(dated)) ...above];

  final said = around
      .map((l) => value(_titleLine, l))
      .nonNulls
      .where((t) => t.split(' ').length <= 8)
      .firstOrNull;
  var where = around.map((l) => value(_placeLine, l)).nonNulls.firstOrNull;

  final titles = above.where(plain).map(titleIn).where(fits).toList();
  final next = below
      .take(2)
      .where((l) => plain(l) && !_statement.hasMatch(l))
      .map(titleIn)
      .where(fits)
      .toList();
  bool noPlace(String title) => !place(title);
  final own = titleIn(lines[index]);
  final ownIsPlace = fits(own) && place(own);
  final t =
      said ??
      (fits(own) && !ownIsPlace ? own : null) ??
      titles.where(_namesEvent).firstOrNull ??
      next.where(_namesEvent).firstOrNull ??
      titles.where(noPlace).firstOrNull ??
      next.where(noPlace).firstOrNull ??
      below
          .where(plain)
          .map(titleIn)
          .where((t) => fits(t) && noPlace(t))
          .firstOrNull ??
      tr.commonEvent;

  if (where == null && ownIsPlace) where = own;
  where ??= [
    ...next,
    if (!up.any(dated)) ...titles,
  ].where((n) => n != t && place(n)).firstOrNull;
  if (where == null) {
    final addresses = [
      ...above.reversed,
      ...below,
    ].where(_address.hasMatch).take(2);
    if (addresses.isNotEmpty) where = addresses.join(', ');
  }

  final title = '${t[0].toUpperCase()}${t.substring(1)}';
  return (
    title: title.length > 60 ? '${title.substring(0, 57)}…' : title,
    place: where ?? '',
  );
}

/// What a sentence is about, once the date is out of it: "Der Elternabend
/// ist am 19.11." leaves "Der Elternabend ist".
String _sentence(String text) {
  final first = _firstSentence.firstMatch(text)?[1] ?? text;
  return first
      .replaceFirst(_trailingVerb, '')
      .replaceFirst(_leadingVerb, '')
      .trim();
}

/// [line] without its dates, times and the small words around them.
String _clean(String line) {
  // Where a date stood, for the small words that led up to it.
  const date = '\u0000';
  // Short weekdays first: they are only recognised before a date.
  var t = line
      .replaceAll(_shortWeekday, date)
      .replaceAll(_weekday, date)
      .replaceAll(_named, date)
      .replaceAll(_monthFirst, date)
      .replaceAll(_slashed, date)
      .replaceAll(_numeric, date)
      .replaceAll(_meridiem, date)
      .replaceAll(_aLas, date)
      .replaceAll(_time, date)
      .replaceAll(_beforeDate, '')
      .replaceAll(date, ' ')
      .replaceAll(_allDay, ' ')
      .replaceAll(RegExp(r'[\s,;:–—\-|•*.]+$'), '')
      .replaceAll(RegExp(r'[\s,;:–—\-|•*]+'), ' ')
      .trim();
  // Small words only at the edges: inside they belong to the title
  // ("Fiesta de otoño", "Fest am See").
  var words = t.split(' ');
  bool filler(String word) =>
      _fillers.contains(word.toLowerCase()) ||
      _germanFillers.contains(word.toLowerCase());
  while (words.isNotEmpty && filler(words.first)) {
    words = words.sublist(1);
  }
  while (words.isNotEmpty && filler(words.last)) {
    words = words.sublist(0, words.length - 1);
  }
  return words.join(' ');
}

const _germanFillers = {'am', 'um', 'vom', 'von', 'bis', 'ab', 'den'};

/// "am ", ", den " and the like directly before a date.
final _beforeDate = RegExp(
  '(?:\\b(?:${_germanFillers.join('|')})\\b[\\s,]*)+(?=\u0000)',
  caseSensitive: false,
);

final _allDay = RegExp(
  r'\b(?:ganztägig|all day|todo el día)\b',
  caseSensitive: false,
);

/// What a quick entry names: "Donnerstag 16 Uhr Kinderarzt", "morgen Müll
/// rausbringen", "next Friday 3 pm dentist", "mañana a las 9 pediatra".
class QuickEntry {
  const QuickEntry({
    required this.title,
    this.days = const [],
    this.lastDay,
    this.time,
  });

  /// What is left once the day and time are taken out (may be empty).
  final String title;

  /// The days it can mean, as dates without a time, the nearest first:
  /// none (no day named), one, or two to choose from ("nächsten
  /// Donnerstag" on a Monday: this week's or the next).
  final List<DateTime> days;

  /// The last day of a range ("12.–16.10."), else null.
  final DateTime? lastDay;

  /// Start hour and minute, with end hour and minute when given.
  final (int, int, int?, int?)? time;

  bool get ambiguous => days.length > 1;
}

const _weekdayNumbers = {
  'montag': 1, 'dienstag': 2, 'mittwoch': 3, 'donnerstag': 4,
  'freitag': 5, 'samstag': 6, 'sonntag': 7, //
  'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4,
  'friday': 5, 'saturday': 6, 'sunday': 7, //
  'lunes': 1, 'martes': 2, 'miércoles': 3, 'miercoles': 3, 'jueves': 4,
  'viernes': 5, 'sábado': 6, 'sabado': 6, 'domingo': 7,
};

/// "nächsten Donnerstag", "next Thursday", "el próximo jueves": this week's
/// or the next week's (people mean both).
const _nextWords =
    r'nächsten|nächste|nächster|naechsten|next|próximo|proximo|próxima|proxima';

/// "kommenden Donnerstag", "this Thursday", "este jueves": the next one.
const _thisWords =
    r'kommenden|kommende|diesen|diese|dieser|this|coming|este|esta';

final _quickWeekday = RegExp(
  '(?<![a-zäöüßáéíóúñ])(?:(?:am|on|el)\\s+)?(?:($_nextWords|$_thisWords)\\s+)?'
  '(${_weekdayNumbers.keys.join('|')})(?:\\s+(que viene))?(?![a-zäöüßáéíóúñ])',
  caseSensitive: false,
);

/// "Do 16 Uhr …", "Thu 4 pm …": a short weekday, only at the start (inside
/// a title "So" and "Sa" are words).
final _quickShortDay = RegExp(
  r'^(Mo|Di|Mi|Do|Fr|Sa|So|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\.?(?=\s|$)',
);

const _shortDayNumbers = {
  'Mo': 1, 'Di': 2, 'Mi': 3, 'Do': 4, 'Fr': 5, 'Sa': 6, 'So': 7, //
  'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4, 'Fri': 5, 'Sat': 6, 'Sun': 7,
};

/// "heute", "morgen", "übermorgen" and their English and Spanish words;
/// "mañana" after "la" is the morning ("a las 9 de la mañana").
final _quickRelative = RegExp(
  r'(?<![a-zäöüßáéíóúñ])(?:(übermorgen|uebermorgen|day after tomorrow|pasado mañana)'
  r'|(heute|today|hoy)|(morgen|tomorrow|(?<!la\s)mañana))(?![a-zäöüßáéíóúñ])',
  caseSensitive: false,
);

/// "in 3 Tagen", "in einer Woche", "in two weeks", "en 3 días".
final _quickIn = RegExp(
  r'(?<![a-zäöüßáéíóúñ])(?:in|en)\s+(\d{1,3}|einem|einer|zwei|drei|vier|a|one|two|three|four|un|una|dos|tres|cuatro)\s+'
  r'(tag|tagen|woche|wochen|day|days|week|weeks|día|días|dia|dias|semana|semanas)(?![a-zäöüßáéíóúñ])',
  caseSensitive: false,
);

/// A bare German "um 16" (with "Uhr" the general times find it).
final _quickUm = RegExp(r'\bum\s+(\d{1,2})(?![\d:.])', caseSensitive: false);

const _smallNumbers = {
  'einem': 1,
  'einer': 1,
  'a': 1,
  'one': 1,
  'un': 1,
  'una': 1,
  'zwei': 2,
  'two': 2,
  'dos': 2,
  'drei': 3,
  'three': 3,
  'tres': 3,
  'vier': 4,
  'four': 4,
  'cuatro': 4,
};

/// Reads a quick entry. [today] is the family's day (its time is ignored);
/// days without a year are the next such day, as in [extractEvents].
QuickEntry parseQuickEntry(
  String text, {
  required DateTime today,
  String? language,
}) {
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final lang = language ?? guessLanguage(line, fallback: appLanguage);
  final base = DateTime(today.year, today.month, today.day);
  DateTime plus(int days) => DateTime(base.year, base.month, base.day + days);
  // What is taken out becomes spaces of the same length, so the places of
  // the other matches in [line] stay right.
  var rest = line;
  var days = <DateTime>[];
  DateTime? lastDay;

  final dates = _dates(line, base, lang).toList();
  if (dates.isNotEmpty) {
    days = [dates.first.day];
    lastDay = dates.first.lastDay;
  } else if (_quickIn.firstMatch(line) case final m?) {
    final n = int.tryParse(m[1]!) ?? _smallNumbers[m[1]!.toLowerCase()]!;
    final unit = m[2]!.toLowerCase();
    final week =
        unit.startsWith('woche') ||
        unit.startsWith('week') ||
        unit.startsWith('semana');
    days = [plus(week ? 7 * n : n)];
    rest = _blank(rest, m);
  } else if (_quickRelative.firstMatch(line) case final m?) {
    // "heute Morgen" is this morning: the day stays today.
    final saysToday = RegExp(
      r'(?<![a-zäöüß])(heute|today|hoy)(?![a-zäöüß])',
      caseSensitive: false,
    ).hasMatch(line);
    days = [plus(saysToday ? 0 : (m[1] != null ? 2 : (m[2] != null ? 0 : 1)))];
    rest = rest.replaceAllMapped(_quickRelative, (m) => ' ' * m[0]!.length);
  } else if (_quickWeekday.firstMatch(line) ?? _quickShortDay.firstMatch(line)
      case final m?) {
    final long = m.pattern == _quickWeekday;
    final wanted = long
        ? _weekdayNumbers[m[2]!.toLowerCase()]!
        : _shortDayNumbers[m[1]!]!;
    final ahead = (wanted - base.weekday) % 7;
    final word = long ? m[1]?.toLowerCase() ?? '' : '';
    final next =
        RegExp('^($_nextWords)\$').hasMatch(word) || (long && m[3] != null);
    final upcoming = RegExp('^($_thisWords)\$').hasMatch(word);
    if (ahead == 0) {
      // Today's weekday: today, or the same day next week.
      days = next ? [plus(7)] : (upcoming ? [plus(7)] : [plus(0), plus(7)]);
    } else {
      days = next ? [plus(ahead), plus(ahead + 7)] : [plus(ahead)];
    }
    rest = _blank(rest, m);
  }

  var time = _firstTime(line, lang);
  final um = time == null ? _quickUm.firstMatch(line) : null;
  if (um != null && int.parse(um[1]!) <= 23) {
    time = (int.parse(um[1]!), 0, null, null);
    rest = _blank(rest, um);
  }
  // Leftover words of the day ("am", "el", "next") go with it.
  final title = _clean(rest)
      .replaceAll(
        RegExp(
          '(?<![a-zäöüßáéíóúñ])($_nextWords|$_thisWords|que viene)(?![a-zäöüßáéíóúñ])',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return QuickEntry(
    title: title.length > 120 ? '${title.substring(0, 117)}…' : title,
    days: days,
    lastDay: lastDay,
    time: time,
  );
}

String _blank(String text, Match m) =>
    text.replaceRange(m.start, m.end, ' ' * (m.end - m.start));
