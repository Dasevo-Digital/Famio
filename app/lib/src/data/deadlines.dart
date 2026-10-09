import 'package:famio_client/famio_client.dart';

import 'family_extras.dart';
import '../l10n.dart';

/// Recurring deadlines (car, house, pets).
extension DeadlineData on SyncEngine {
  /// Open ones first by due date, then the done one-offs.
  List<Deadline> get deadlines =>
      records(Collections.deadlines).map(Deadline.fromRecord).toList()
        ..sort((a, b) {
          if (a.done != b.done) return a.done ? 1 : -1;
          return a.due.compareTo(b.due);
        });

  void saveDeadline(Deadline d) => put(Collections.deadlines, d.id, d.toData());

  void deleteDeadline(String id) => delete(Collections.deadlines, id);

  /// Whether [d] is the signed-in member's to take care of: theirs, or
  /// nobody's and they are an adult.
  bool deadlineIsMine(Deadline d) =>
      d.assigneeId == memberId || (d.assigneeId == null && iAmAdult);

  /// Open deadlines due within their reminder lead (at least a week) or
  /// overdue, for the start page.
  List<Deadline> deadlinesSoon(DateTime now) => [
    for (final d in deadlines)
      if (!d.done && d.daysLeft(now) <= (d.leadDays < 7 ? 7 : d.leadDays)) d,
  ];
}

/// "überfällig", "heute", "morgen", "in 12 Tagen".
String deadlineWhen(Deadline d, DateTime now) {
  final days = d.daysLeft(now);
  return switch (days) {
    < 0 =>
      days == -1
          ? tr.deadlinesOverdueSinceYesterday
          : tr.deadlinesOverdueDaysDays(-days),
    0 => tr.deadlinesDueToday,
    1 => tr.deadlinesDueTomorrow,
    _ => tr.deadlinesDaysDays(days),
  };
}
