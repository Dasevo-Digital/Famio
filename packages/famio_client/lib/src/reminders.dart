import 'package:famio_shared/famio_shared.dart';

/// A notification this device should show at [at].
class DueReminder {
  const DueReminder({
    required this.key,
    required this.at,
    required this.title,
    this.occurrence,
    this.task,
    this.body,
  });

  /// Stable identity, so rescheduling does not duplicate notifications.
  final String key;
  final DateTime at;
  final String title;

  /// Set for calendar reminders.
  final Occurrence? occurrence;

  /// Set for task reminders.
  final Task? task;

  /// Ready-made text for other reminders (check-ups, documents, …).
  final String? body;

  /// Positive 31-bit id derived from [key] (FNV-1a), as notification APIs
  /// want an int.
  int get notificationId {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }
}

/// Reminders for [memberId] that fire within `[from, to)`, earliest first.
///
/// Events remind their participants (everyone if nobody is picked); tasks
/// remind their assignee (everyone if unassigned) unless already done.
List<DueReminder> upcomingReminders({
  required Iterable<CalendarEvent> events,
  required Iterable<Task> tasks,
  required String memberId,
  required DateTime from,
  required DateTime to,
  int limit = 64,
}) {
  final result = <DueReminder>[];
  for (final event in events) {
    final minutes = event.reminderMinutes;
    if (minutes == null || !event.involves(memberId)) continue;
    final offset = Duration(minutes: minutes);
    for (final o in event.occurrencesBetween(
      from.add(offset),
      to.add(offset),
    )) {
      final at = o.start.subtract(offset);
      // occurrencesBetween also returns events already running at `from`.
      if (at.isBefore(from) || !at.isBefore(to)) continue;
      result.add(
        DueReminder(
          key: 'event:${o.key}',
          at: at,
          title: event.title,
          occurrence: o,
        ),
      );
    }
  }
  for (final task in tasks) {
    final at = task.remindAt;
    if (at == null || task.done) continue;
    if (task.assigneeId != null && task.assigneeId != memberId) continue;
    if (at.isBefore(from) || !at.isBefore(to)) continue;
    result.add(
      DueReminder(
        key: 'task:${task.id}@${at.toIso8601String()}',
        at: at,
        title: task.title,
        task: task,
      ),
    );
  }
  result.sort((a, b) => a.at.compareTo(b.at));
  return result.take(limit).toList();
}
