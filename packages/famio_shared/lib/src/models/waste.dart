import '../sync_record.dart';
import 'event.dart';
import '../texts.dart';

/// Kinds of bins, recognised from the titles of the municipality's
/// calendar ("Gelber Sack", "Altpapier", "Bioabfall" …).
enum WasteKind {
  residual('Restmüll', '⚫'),
  organic('Biotonne', '🟤'),
  paper('Papier', '🔵'),
  packaging('Gelbe Tonne', '🟡'),
  glass('Glas', '🟢'),
  garden('Grünschnitt', '🌿'),
  bulky('Sperrmüll', '🛋️'),
  hazardous('Schadstoffe', '☣️'),
  other('Abholung', '🗑️');

  const WasteKind(this._label, this.emoji);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('WasteKind.$name', _label);
  final String emoji;

  /// The kind a calendar title names, or null if it names none.
  ///
  /// Whole words count, not parts of words: "Restmüll" and "Bio-Tonne"
  /// name bins, "Restaurant", "Biologie", "Kindergarten", "Glaserei",
  /// "Gelbe Karte" and "Müller" do not.
  static WasteKind? of(String title) {
    final words = [
      for (final w in title.toLowerCase().split(_separator))
        if (w.isNotEmpty) w,
    ];
    if (words.isEmpty) return null;
    final text = ' ${words.join(' ')} ';
    for (final (kind, keys) in _keys) {
      if (keys.any((k) => _matches(words, text, k))) return kind;
    }
    return null;
  }

  static final _separator = RegExp(r'[^a-z0-9äöüßáéíóúñ]+');

  /// Key syntax:
  /// - "stem": a word starts with it ("Wertstofftonne"),
  /// - "=word": a word is exactly it ("Glas", "Papier"),
  /// - "-stem": a word ends with it ("Hausmüll", not "Müller"),
  /// - "*stem": a word contains it ("Müllabfuhr"),
  /// - "+stem": the stem joined to a bin word ("Restmüll", "Biotonne") or
  ///   followed by one ("Bio-Tonne", "Rest Müll"),
  /// - with a space: these words in a row ("gelber sack").
  static bool _matches(List<String> words, String text, String key) {
    if (key.contains(' ')) return text.contains(' $key');
    final stem = key.substring(1);
    switch (key[0]) {
      case '=':
        return words.contains(stem);
      case '-':
        return words.any((w) => w.endsWith(stem));
      case '*':
        return words.any((w) => w.contains(stem));
      case '+':
        for (var i = 0; i < words.length; i++) {
          final w = words[i];
          if (!w.startsWith(stem)) continue;
          if (w.length > stem.length && _binWord(w.substring(stem.length))) {
            return true;
          }
          if (w == stem && i + 1 < words.length && _binWord(words[i + 1])) {
            return true;
          }
        }
        return false;
      default:
        return words.any((w) => w.startsWith(key));
    }
  }

  /// Whether [word] starts with a word for bins or their collection
  /// ("Biogut", but not "Restgutschein").
  static bool _binWord(String word) =>
      _bins.any(word.startsWith) || _shortBins.contains(word);

  static const _shortBins = ['gut', 'bin', 'bins'];

  static const _bins = [
    'tonne',
    'müll',
    'muell',
    'abfall',
    'abfäll',
    'abfaell',
    'sack',
    'säck',
    'saeck',
    'container',
    'abfuhr',
    'sammlung',
    'abholung',
    'mobil',
    'entsorgung',
    'leerung',
    'behälter',
    'collection',
    'pickup',
    'recycling',
    'waste',
  ];

  // Order matters: "Bioabfall" before "Abfall", "Altpapier" before others.
  // German words first, then English and Spanish ones.
  static const _keys = [
    (
      WasteKind.packaging,
      [
        'gelber sack',
        'gelbe sack',
        'gelbe säcke',
        'gelbe saecke',
        'gelbe tonne',
        '+gelb',
        'wertstoff',
        'leichtverpack',
        '=lvp',
        'verpackung',
        'recycl',
        'packaging',
        'envases',
        'contenedor amarillo',
      ],
    ),
    (
      WasteKind.paper,
      [
        '=papier',
        '+papier',
        'altpapier',
        '=ppk',
        '=pappe',
        '+pappe',
        'blaue tonne',
        '+blau',
        '=paper',
        'cardboard',
        '=papel',
      ],
    ),
    (
      WasteKind.organic,
      [
        '+bio',
        'braune tonne',
        '+braun',
        'kompost',
        'compost',
        'organic',
        'food waste',
        'orgánic',
      ],
    ),
    (WasteKind.glass, ['=glas', '+glas', 'altglas', 'vidrio']),
    (
      WasteKind.garden,
      [
        'grünschnitt',
        'gruenschnitt',
        '+garten',
        '=laub',
        '+laub',
        '+weihnachtsbaum',
        '+tannenbaum',
        '+christbaum',
        'baumschnitt',
        'yard waste',
        'garden waste',
        'christmas tree pickup',
        'christmas tree collection',
        '=poda',
        'restos de jardín',
        'residuos de jardín',
      ],
    ),
    (
      WasteKind.bulky,
      ['+sperr', 'sperrgut', '=bulky', 'voluminos', '=enseres'],
    ),
    (
      WasteKind.hazardous,
      ['schadstoff', 'problemstoff', 'sondermüll', 'hazardous', 'peligros'],
    ),
    (
      WasteKind.residual,
      [
        '+rest',
        'hausmüll',
        'hausmuell',
        'graue tonne',
        'schwarze tonne',
        '+grau',
        '+schwarz',
        '=trash',
        '=garbage',
        '=rubbish',
      ],
    ),
    (
      WasteKind.other,
      [
        '-müll',
        '-muell',
        '+müll',
        '+muell',
        '*abfall',
        '*abfäll',
        '*abfaell',
        '-tonne',
        '-tonnen',
        '*abfuhr',
        '=waste',
        'bin day',
        'bin collection',
        '=bins',
        '=basura',
        '=residuos',
        'contenedor',
      ],
    ),
  ];
}

/// One pickup day with the bins collected.
class WastePickup {
  const WastePickup(this.day, this.kinds, this.titles);

  /// Local midnight.
  final DateTime day;
  final List<WasteKind> kinds;

  /// The calendar's own wording, e.g. "Gelber Sack (14-tägl.)".
  final List<String> titles;

  /// "🟡 Gelbe Tonne, 🔵 Papier".
  String get label =>
      [for (final k in kinds) '${k.emoji} ${k.label}'].join(', ');
}

/// How the family handles the bins, stored in `Collections.wasteSettings`
/// (one record, id [WasteSettings.recordId]).
class WasteSettings {
  const WasteSettings({
    this.sourceId,
    this.memberIds = const [],
    this.rotate = false,
    this.remindHour = 18,
  });

  static const recordId = 'family';

  factory WasteSettings.fromRecord(SyncRecord r) => WasteSettings(
    sourceId: r.data['sourceId'] as String?,
    memberIds: [
      for (final m in r.data['memberIds'] as List? ?? const []) m as String,
    ],
    rotate: r.data['rotate'] as bool? ?? false,
    remindHour: ((r.data['remindHour'] as num?)?.toInt() ?? 18).clamp(0, 23),
  );

  /// The calendar subscription with the pickup days; null: Famio picks
  /// all-day events whose title names a bin.
  final String? sourceId;

  /// Who puts the bins out; empty: every adult is reminded.
  final List<String> memberIds;

  /// Week by week one of [memberIds] instead of all of them.
  final bool rotate;

  /// Hour of the reminder on the evening before.
  final int remindHour;

  /// Who is in charge of [pickup]: everyone in [memberIds], or the one
  /// whose turn it is that week (weeks counted from Monday).
  List<String> responsibleFor(DateTime pickup) {
    if (!rotate || memberIds.length < 2) return memberIds;
    final day = DateTime.utc(pickup.year, pickup.month, pickup.day);
    // 5 January 1970 was a Monday.
    final week = day.difference(DateTime.utc(1970, 1, 5)).inDays ~/ 7;
    return [memberIds[week % memberIds.length]];
  }

  /// Whether [event] is a pickup day: any entry of the chosen calendar,
  /// or else an all-day entry whose title names a bin. Birthdays and
  /// public holidays never are ("🎂 Lisa Müller").
  bool isPickup(CalendarEvent event) {
    if (sourceId != null) return event.sourceId == sourceId;
    final source = event.sourceId ?? '';
    return event.allDay &&
        !source.startsWith('birthday:') &&
        !source.startsWith('holiday:') &&
        WasteKind.of(event.title) != null;
  }

  /// The pickups among [occurrences], one per day, in order.
  List<WastePickup> pickups(Iterable<Occurrence> occurrences) {
    final byDay = <DateTime, (Set<WasteKind>, List<String>)>{};
    for (final o in occurrences) {
      if (!isPickup(o.event)) continue;
      final kind = WasteKind.of(o.event.title);
      final day = DateTime(o.start.year, o.start.month, o.start.day);
      final entry = byDay.putIfAbsent(day, () => ({}, []));
      entry.$1.add(kind ?? WasteKind.other);
      entry.$2.add(o.event.title);
    }
    final days = byDay.keys.toList()..sort();
    return [
      for (final d in days)
        WastePickup(
          d,
          WasteKind.values.where(byDay[d]!.$1.contains).toList(),
          byDay[d]!.$2,
        ),
    ];
  }

  Map<String, Object?> toData() => {
    'sourceId': sourceId,
    'memberIds': memberIds,
    'rotate': rotate,
    'remindHour': remindHour,
  };
}
