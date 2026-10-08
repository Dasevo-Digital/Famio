import '../sync_record.dart';
import 'event.dart';

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

  const WasteKind(this.label, this.emoji);

  final String label;
  final String emoji;

  /// The kind a calendar title names, or null if it names none.
  static WasteKind? of(String title) {
    final t = title.toLowerCase();
    for (final (kind, words) in _words) {
      if (words.any((w) => _has(t, w))) return kind;
    }
    return null;
  }

  /// "^rest" only at the start of a word ("Restmüll", not "Forest").
  static bool _has(String text, String word) {
    if (!word.startsWith('^')) return text.contains(word);
    final w = word.substring(1);
    for (var i = text.indexOf(w); i >= 0; i = text.indexOf(w, i + 1)) {
      if (i == 0 || !RegExp('[a-zäöüß]').hasMatch(text[i - 1])) return true;
    }
    return false;
  }

  // Order matters: "Bioabfall" before "Abfall", "Altpapier" before others.
  static const _words = [
    (
      WasteKind.packaging,
      ['gelb', 'wertstoff', 'leichtverpack', '^lvp', 'verpackung'],
    ),
    (WasteKind.paper, ['papier', '^ppk', 'pappe', 'blaue tonne']),
    (WasteKind.organic, ['^bio', 'braune tonne', 'kompost']),
    (WasteKind.glass, ['glas']),
    (
      WasteKind.garden,
      [
        'grünschnitt',
        'gruenschnitt',
        'garten',
        '^laub',
        'weihnachtsbaum',
        'tannenbaum',
        'baumschnitt',
      ],
    ),
    (WasteKind.bulky, ['sperr']),
    (WasteKind.hazardous, ['schadstoff', 'problemstoff', 'sondermüll']),
    (
      WasteKind.residual,
      ['^rest', 'hausmüll', 'hausmuell', 'graue tonne', 'schwarze tonne'],
    ),
    (WasteKind.other, ['müll', 'muell', 'abfall', 'tonne', 'abfuhr']),
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

  /// The pickups among [occurrences], one per day, in order.
  List<WastePickup> pickups(Iterable<Occurrence> occurrences) {
    final byDay = <DateTime, (Set<WasteKind>, List<String>)>{};
    for (final o in occurrences) {
      final fromSource = sourceId != null && o.event.sourceId == sourceId;
      final kind = WasteKind.of(o.event.title);
      if (sourceId != null ? !fromSource : (kind == null || !o.event.allDay)) {
        continue;
      }
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
