import '../sync_record.dart';
import 'chores.dart';

/// A family holiday, stored in `Collections.vacations` (adults only): from
/// [from] to [to] (local days, both included) chores and routines are not
/// due and no one is reminded of the bins; with [allowance] no pocket money
/// is booked either.
class Vacation {
  const Vacation({
    required this.id,
    required this.from,
    required this.to,
    this.title = '',
    this.allowance = false,
  });

  factory Vacation.fromRecord(SyncRecord r) {
    DateTime day(Object? v) {
      final d = v is String ? DateTime.tryParse(v) : null;
      return d == null ? DateTime(2000) : DateTime(d.year, d.month, d.day);
    }

    return Vacation(
      id: r.id,
      from: day(r.data['from']),
      to: day(r.data['to']),
      title: r.data['title'] as String? ?? '',
      allowance: r.data['allowance'] as bool? ?? false,
    );
  }

  final String id;
  final DateTime from;
  final DateTime to;
  final String title;

  /// Pocket money pauses too (not only chores and reminders).
  final bool allowance;

  /// Whether [day] (any time of it) falls into this holiday.
  bool covers(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(from) && !d.isAfter(to);
  }

  Map<String, Object?> toData() => {
    'from': dayKey(from),
    'to': dayKey(to),
    if (title.isNotEmpty) 'title': title,
    if (allowance) 'allowance': true,
  };
}

/// The holiday [day] falls into, if any.
Vacation? vacationOn(Iterable<Vacation> vacations, DateTime day) {
  for (final v in vacations) {
    if (v.covers(day)) return v;
  }
  return null;
}
