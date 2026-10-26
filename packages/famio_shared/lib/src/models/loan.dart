import '../sync_record.dart';

/// Something the family lent to someone or borrowed from them: the drill
/// at the neighbours', the book from Mia's friend. Stored in
/// `Collections.loans`.
class Loan {
  const Loan({
    required this.id,
    required this.title,
    this.lentOut = true,
    this.person = '',
    this.memberId,
    this.since,
    this.due,
    this.returned = false,
    this.note = '',
  });

  factory Loan.fromRecord(SyncRecord r) => Loan(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    lentOut: r.data['lentOut'] as bool? ?? true,
    person: r.data['person'] as String? ?? '',
    memberId: r.data['memberId'] as String?,
    since: _date(r.data['since']),
    due: _date(r.data['due']),
    returned: r.data['returned'] as bool? ?? false,
    note: r.data['note'] as String? ?? '',
  );

  final String id;

  /// What it is ("Bohrmaschine").
  final String title;

  /// True: lent to [person]; false: borrowed from them.
  final bool lentOut;

  /// Who has it, or whom it belongs to ("Familie Weber").
  final String person;

  /// Who in the family lent or borrowed it; reminded when it is due.
  final String? memberId;
  final DateTime? since;

  /// Back by this day (local midnight), if agreed.
  final DateTime? due;
  final bool returned;
  final String note;

  /// Still out and past [due] on [today].
  bool overdueOn(DateTime today) =>
      !returned &&
      due != null &&
      due!.isBefore(DateTime(today.year, today.month, today.day));

  Loan copyWith({bool? returned}) => Loan(
    id: id,
    title: title,
    lentOut: lentOut,
    person: person,
    memberId: memberId,
    since: since,
    due: due,
    returned: returned ?? this.returned,
    note: note,
  );

  Map<String, Object?> toData() => {
    'title': title,
    'lentOut': lentOut,
    'person': person,
    'memberId': memberId,
    'since': since == null ? null : _format(since!),
    'due': due == null ? null : _format(due!),
    'returned': returned,
    'note': note,
  };
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
