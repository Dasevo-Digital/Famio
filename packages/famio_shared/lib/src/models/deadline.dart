import '../sync_record.dart';
import '../texts.dart';

/// What a deadline is about.
enum DeadlineArea {
  car('Auto', '🚗'),
  home('Haus & Wohnung', '🏠'),
  pet('Haustiere', '🐾'),
  other('Sonstiges', '📌');

  const DeadlineArea(this._label, this.emoji);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('DeadlineArea.$name', _label);
  final String emoji;
}

/// A recurring date that must not be missed: the car's inspection, the
/// boiler service, the dog's vaccination … stored in
/// `Collections.deadlines`.
class Deadline {
  const Deadline({
    required this.id,
    required this.title,
    required this.due,
    this.area = DeadlineArea.other,
    this.subject = '',
    this.repeatMonths,
    this.leadDays = 14,
    this.assigneeId,
    this.note = '',
    this.lastDone,
    this.done = false,
  });

  factory Deadline.fromRecord(SyncRecord r) => Deadline(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    due: _date(r.data['due']) ?? DateTime(2000),
    area:
        DeadlineArea.values
            .where((a) => a.name == r.data['area'])
            .firstOrNull ??
        DeadlineArea.other,
    subject: r.data['subject'] as String? ?? '',
    repeatMonths: (r.data['repeatMonths'] as num?)?.toInt(),
    leadDays: ((r.data['leadDays'] as num?)?.toInt() ?? 14).clamp(0, 365),
    assigneeId: r.data['assigneeId'] as String?,
    note: r.data['note'] as String? ?? '',
    lastDone: _date(r.data['lastDone']),
    done: r.data['done'] as bool? ?? false,
  );

  final String id;
  final String title;

  /// The day it is due (local midnight).
  final DateTime due;
  final DeadlineArea area;

  /// Which car, which pet …: "Golf", "Bello".
  final String subject;

  /// Comes back this many months after it was done; null: once.
  final int? repeatMonths;

  /// Reminds this many days before [due].
  final int leadDays;

  /// Who takes care of it; null: the adults.
  final String? assigneeId;
  final String note;
  final DateTime? lastDone;

  /// A one-off deadline that was taken care of.
  final bool done;

  /// "HU/TÜV · Golf".
  String get label => subject.isEmpty ? title : '$title · $subject';

  /// Days from [today] until [due]; negative when overdue.
  int daysLeft(DateTime today) => DateTime.utc(
    due.year,
    due.month,
    due.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;

  /// Taken care of on [day]: a recurring one moves on by [repeatMonths]
  /// from that day, a one-off one is done.
  Deadline completed(DateTime day) {
    final on = DateTime(day.year, day.month, day.day);
    final months = repeatMonths;
    return _copy(
      due: months == null ? due : _addMonths(on, months),
      lastDone: on,
      done: months == null,
    );
  }

  Deadline _copy({DateTime? due, DateTime? lastDone, bool? done}) => Deadline(
    id: id,
    title: title,
    due: due ?? this.due,
    area: area,
    subject: subject,
    repeatMonths: repeatMonths,
    leadDays: leadDays,
    assigneeId: assigneeId,
    note: note,
    lastDone: lastDone ?? this.lastDone,
    done: done ?? this.done,
  );

  Map<String, Object?> toData() => {
    'title': title,
    'due': _format(due),
    'area': area.name,
    'subject': subject,
    'repeatMonths': repeatMonths,
    'leadDays': leadDays,
    'assigneeId': assigneeId,
    'note': note,
    'lastDone': lastDone == null ? null : _format(lastDone!),
    if (done) 'done': true,
  };
}

/// A ready-made deadline to pick from.
class DeadlinePreset {
  const DeadlinePreset(this.area, this._title, this.repeatMonths, [this._hint]);

  final DeadlineArea area;
  final String _title;
  String get title => sharedText('DeadlinePreset|$_title', _title);
  final int? repeatMonths;
  final String? _hint;
  String? get hint => switch (_hint) {
    final t? => sharedText('DeadlinePreset|$t', t),
    null => null,
  };
}

const deadlinePresets = [
  DeadlinePreset(
    DeadlineArea.car,
    'HU/TÜV',
    24,
    'Monat steht auf der Plakette am hinteren Kennzeichen',
  ),
  DeadlinePreset(DeadlineArea.car, 'Inspektion', 12),
  DeadlinePreset(
    DeadlineArea.car,
    'Winterreifen aufziehen',
    12,
    'Faustregel: von Oktober bis Ostern',
  ),
  DeadlinePreset(DeadlineArea.car, 'Sommerreifen aufziehen', 12),
  DeadlinePreset(DeadlineArea.car, 'Kfz-Versicherung prüfen', 12),
  DeadlinePreset(DeadlineArea.car, 'Verbandkasten tauschen', null),
  DeadlinePreset(DeadlineArea.home, 'Heizungswartung', 12),
  DeadlinePreset(DeadlineArea.home, 'Rauchmelder testen', 12),
  DeadlinePreset(DeadlineArea.home, 'Schornsteinfeger', 12),
  DeadlinePreset(DeadlineArea.home, 'Wasserfilter wechseln', 6),
  DeadlinePreset(DeadlineArea.home, 'Feuerlöscher prüfen', 24),
  DeadlinePreset(DeadlineArea.home, 'Zählerstände ablesen', 12),
  DeadlinePreset(DeadlineArea.pet, 'Impfung', 12),
  DeadlinePreset(DeadlineArea.pet, 'Entwurmung', 3),
  DeadlinePreset(DeadlineArea.pet, 'Floh- und Zeckenschutz', 1),
  DeadlinePreset(DeadlineArea.pet, 'Tierarzt-Check', 12),
  DeadlinePreset(DeadlineArea.pet, 'Hundesteuer', 12),
];

/// [months] later; the 31st becomes the last day of a shorter month.
DateTime _addMonths(DateTime d, int months) {
  final first = DateTime(d.year, d.month + months);
  final last = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, d.day > last ? last : d.day);
}

DateTime? _date(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _format(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
