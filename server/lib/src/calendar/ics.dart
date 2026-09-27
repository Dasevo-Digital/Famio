import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

/// One content line: `NAME;PARAM=VALUE:value`.
class IcsProperty {
  IcsProperty(this.name, this.value, [this.params = const {}]);

  final String name;
  final String value;
  final Map<String, String> params;

  String get text => unescapeText(value);
}

/// A `BEGIN:X … END:X` block with its properties and nested components.
class IcsComponent {
  IcsComponent(this.name);

  final String name;
  final properties = <IcsProperty>[];
  final children = <IcsComponent>[];

  IcsProperty? property(String name) =>
      properties.where((p) => p.name == name).firstOrNull;

  Iterable<IcsProperty> all(String name) =>
      properties.where((p) => p.name == name);

  Iterable<IcsComponent> components(String name) =>
      children.where((c) => c.name == name);
}

/// Parses iCalendar text (RFC 5545) into its component tree. Lenient about
/// line endings and unknown content, as real-world feeds vary.
IcsComponent parseIcs(String text) {
  final root = IcsComponent('ROOT');
  final stack = [root];
  // Unfold: a line starting with space or tab continues the previous one.
  final unfolded = text
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'\n[ \t]'), '');
  for (final line in unfolded.split('\n')) {
    if (line.trim().isEmpty) continue;
    final prop = _parseLine(line);
    if (prop == null) continue;
    if (prop.name == 'BEGIN') {
      final component = IcsComponent(prop.value.toUpperCase());
      stack.last.children.add(component);
      stack.add(component);
    } else if (prop.name == 'END') {
      if (stack.length > 1) stack.removeLast();
    } else {
      stack.last.properties.add(prop);
    }
  }
  return root;
}

IcsProperty? _parseLine(String line) {
  // The value starts at the first colon outside of quoted parameter values.
  var inQuotes = false;
  var colon = -1;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') inQuotes = !inQuotes;
    if (c == ':' && !inQuotes) {
      colon = i;
      break;
    }
  }
  if (colon <= 0) return null;
  final head = line.substring(0, colon);
  final value = line.substring(colon + 1);
  final parts = _splitOutsideQuotes(head, ';');
  final params = <String, String>{};
  for (final p in parts.skip(1)) {
    final eq = p.indexOf('=');
    if (eq <= 0) continue;
    params[p.substring(0, eq).toUpperCase()] = p
        .substring(eq + 1)
        .replaceAll('"', '');
  }
  return IcsProperty(parts.first.toUpperCase(), value, params);
}

List<String> _splitOutsideQuotes(String s, String sep) {
  final parts = <String>[];
  var inQuotes = false;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '"') inQuotes = !inQuotes;
    if (s[i] == sep && !inQuotes) {
      parts.add(s.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(s.substring(start));
  return parts;
}

String unescapeText(String v) => v.replaceAllMapped(
  RegExp(r'\\([\;,nN])'),
  (m) => switch (m[1]) {
    'n' || 'N' => '\n',
    final c => c!,
  },
);

String escapeText(String v) => v
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll('\r\n', r'\n')
    .replaceAll('\n', r'\n');

/// Builds iCalendar text with CRLF line endings and 75-octet folding.
class IcsWriter {
  final _buffer = StringBuffer();

  void begin(String name) => line('BEGIN', name);
  void end(String name) => line('END', name);

  void line(
    String name,
    String value, [
    Map<String, String> params = const {},
  ]) {
    final head = StringBuffer(name);
    for (final e in params.entries) {
      head.write(';${e.key}=${e.value}');
    }
    _fold('$head:$value');
  }

  void text(String name, String value) {
    if (value.isNotEmpty) line(name, escapeText(value));
  }

  void _fold(String content) {
    var bytes = 0;
    for (final rune in content.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > 75) {
        _buffer.write('\r\n ');
        bytes = 1;
      }
      _buffer.write(char);
      bytes += size;
    }
    _buffer.write('\r\n');
  }

  @override
  String toString() => _buffer.toString();
}

// --- date and time values ---------------------------------------------------

/// A DATE or DATE-TIME value. [wall] is the wall-clock time in [location],
/// stored as a UTC-flagged [DateTime] (the form the rrule package expects).
class IcsTime {
  const IcsTime(this.wall, {required this.location, this.dateOnly = false});

  final DateTime wall;
  final tz.Location location;
  final bool dateOnly;

  /// The absolute point in time (midnight in [location] for dates).
  DateTime get instant => tz.TZDateTime(
    location,
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
  ).toUtc();

  IcsTime withWall(DateTime wall) =>
      IcsTime(wall, location: location, dateOnly: dateOnly);
}

final _dateTime = RegExp(
  r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$',
);

/// Parses the value of DTSTART, DTEND, EXDATE, RECURRENCE-ID and the like.
/// Floating times (no zone) are interpreted in [fallback].
List<IcsTime> parseIcsTimes(IcsProperty p, tz.Location fallback) => [
  for (final v in p.value.split(',')) ?_parseTime(v.trim(), p.params, fallback),
];

IcsTime? parseIcsTime(IcsProperty? p, tz.Location fallback) =>
    p == null ? null : parseIcsTimes(p, fallback).firstOrNull;

IcsTime? _parseTime(
  String v,
  Map<String, String> params,
  tz.Location fallback,
) {
  final m = _dateTime.firstMatch(v);
  if (m == null) return null;
  int g(int i) => int.parse(m[i]!);
  final dateOnly = m[4] == null || params['VALUE'] == 'DATE';
  final wall = dateOnly
      ? DateTime.utc(g(1), g(2), g(3))
      : DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
  final location = m[7] != null
      ? tz.UTC
      : resolveTimeZone(params['TZID']) ?? fallback;
  return IcsTime(wall, location: location, dateOnly: dateOnly);
}

/// Maps TZID values to IANA locations, including Outlook's Windows names
/// and prefixed forms like `/mozilla.org/20050126_1/Europe/Berlin`.
tz.Location? resolveTimeZone(String? tzid) {
  if (tzid == null || tzid.isEmpty) return null;
  final name = _windowsZones[tzid] ?? tzid;
  final parts = name.split('/').where((p) => p.isNotEmpty).toList();
  for (var take = parts.length; take >= 1; take--) {
    final candidate = parts.sublist(parts.length - take).join('/');
    try {
      return tz.getLocation(candidate);
    } on tz.LocationNotFoundException {
      continue;
    }
  }
  return null;
}

const _windowsZones = {
  'W. Europe Standard Time': 'Europe/Berlin',
  'Central Europe Standard Time': 'Europe/Budapest',
  'Central European Standard Time': 'Europe/Warsaw',
  'Romance Standard Time': 'Europe/Paris',
  'GMT Standard Time': 'Europe/London',
  'E. Europe Standard Time': 'Europe/Chisinau',
  'FLE Standard Time': 'Europe/Kiev',
  'Eastern Standard Time': 'America/New_York',
  'Central Standard Time': 'America/Chicago',
  'Mountain Standard Time': 'America/Denver',
  'Pacific Standard Time': 'America/Los_Angeles',
  'UTC': 'UTC',
  'Coordinated Universal Time': 'UTC',
};

/// Formats a wall time as `yyyyMMdd` or `yyyyMMddTHHmmss` (+`Z` if [utc]).
String formatIcsTime(DateTime t, {bool dateOnly = false, bool utc = false}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final date =
      '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}';
  if (dateOnly) return date;
  return '${date}T${two(t.hour)}${two(t.minute)}${two(t.second)}${utc ? 'Z' : ''}';
}

/// Parses an ISO 8601 duration like `PT1H30M`, `P1D` or `P2W`.
Duration? parseIcsDuration(String? v) {
  if (v == null) return null;
  final m = RegExp(
    r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(v.trim());
  if (m == null) return null;
  int g(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(
    days: g(2) * 7 + g(3),
    hours: g(4),
    minutes: g(5),
    seconds: g(6),
  );
  return m[1] == '-' ? -d : d;
}
