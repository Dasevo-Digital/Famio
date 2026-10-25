import '../sync_record.dart';

/// A personal absence. Unlike [Vacation], this does not pause the whole
/// family; tasks and chores can be shown to [substituteId] for the period.
class MemberAbsence {
  const MemberAbsence({
    required this.id,
    required this.memberId,
    required this.from,
    required this.to,
    this.substituteId,
    this.title = '',
  });

  factory MemberAbsence.fromRecord(SyncRecord r) {
    DateTime day(Object? value) {
      final date = value is String ? DateTime.tryParse(value) : null;
      return date == null
          ? DateTime(2000)
          : DateTime(date.year, date.month, date.day);
    }

    return MemberAbsence(
      id: r.id,
      memberId: r.data['memberId'] as String? ?? '',
      from: day(r.data['from']),
      to: day(r.data['to']),
      substituteId: r.data['substituteId'] as String?,
      title: r.data['title'] as String? ?? '',
    );
  }

  final String id;
  final String memberId;
  final DateTime from;
  final DateTime to;
  final String? substituteId;
  final String title;

  bool covers(DateTime day) {
    final date = DateTime(day.year, day.month, day.day);
    return !date.isBefore(from) && !date.isAfter(to);
  }

  Map<String, Object?> toData() => {
    'memberId': memberId,
    'from': _day(from),
    'to': _day(to),
    'substituteId': substituteId,
    if (title.isNotEmpty) 'title': title,
  };
}

String _day(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

MemberAbsence? absenceFor(
  Iterable<MemberAbsence> absences,
  String memberId,
  DateTime day,
) {
  for (final absence in absences) {
    if (absence.memberId == memberId && absence.covers(day)) return absence;
  }
  return null;
}
