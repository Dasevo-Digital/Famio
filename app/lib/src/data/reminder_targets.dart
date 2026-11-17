import 'package:famio_client/famio_client.dart';

/// What tapping the reminder [r] opens (#385), read from its key: the task,
/// the appointment's date, the child, the page of a deadline, the day in
/// the calendar. Null for reminders that only open the app (the end of an
/// iPhone build, a kitchen timer).
NoticeTarget? reminderTarget(DueReminder r, SyncEngine engine) {
  final key = r.key;
  final colon = key.indexOf(':');
  if (colon < 0) return null;
  final kind = key.substring(0, colon);
  final rest = key.substring(colon + 1);
  String first() => rest.split(':').first;
  DateTime dayOf(DateTime at) => DateTime(at.year, at.month, at.day);
  switch (kind) {
    case 'task':
      final at = rest.lastIndexOf('@');
      final id = at < 0 ? rest : rest.substring(0, at);
      return id.isEmpty ? null : NoticeTarget.task(id);
    case 'event' || 'departure':
      return _event(rest);
    case 'lift':
      // lift:<verb>:<occurrence>
      final next = rest.indexOf(':');
      return next < 0 ? null : _event(rest.substring(next + 1));
    case 'kid':
      return NoticeTarget.child(first());
    case 'log':
      final log = engine.record(Collections.childLogs, rest);
      final child = log == null ? null : ChildLog.fromRecord(log).childId;
      return child == null || child.isEmpty ? null : NoticeTarget.child(child);
    case 'preg':
      return NoticeTarget.pregnancy(first());
    case 'bday':
      // The evening before: still the birthday that opens.
      final eve = key.endsWith(':eve');
      // Calendar days, not 24 hours (a clock change in between).
      return NoticeTarget.day(
        DateTime(r.at.year, r.at.month, r.at.day + (eve ? 1 : 0)),
      );
    case 'day':
      return NoticeTarget.day(DateTime.tryParse(rest) ?? dayOf(r.at));
    case 'week':
      // On Sunday evening for the week from [rest], its Monday.
      return NoticeTarget.day(DateTime.tryParse(rest) ?? dayOf(r.at));
    case 'med':
      return const NoticeTarget.section('health');
    case 'deadline':
      return const NoticeTarget.page(NoticeTarget.deadlines);
    case 'subscription':
      return const NoticeTarget.page(NoticeTarget.subscriptions);
    case 'loan':
      return const NoticeTarget.page(NoticeTarget.loans);
    case 'waste':
      return const NoticeTarget.page(NoticeTarget.waste);
    case 'doc':
      return const NoticeTarget.section('documents');
  }
  return null;
}

/// An occurrence key (`<event id>@<start>`) as a target.
NoticeTarget? _event(String occurrence) =>
    NoticeTarget.decode('${NoticeTarget.eventKind}:$occurrence');
