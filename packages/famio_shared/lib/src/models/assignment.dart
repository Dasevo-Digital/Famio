import 'dart:convert';

import 'package:cryptography/dart.dart';

import '../collections.dart';
import '../calendar_clock.dart';
import '../sync_record.dart';
import 'event.dart';
import 'task.dart';

class AssignmentSettings {
  const AssignmentSettings({this.required = false, this.remindMinutes});

  factory AssignmentSettings.fromData(Map<String, Object?> data) {
    final value = data['assignmentConfirmation'];
    if (value == null) return const AssignmentSettings();
    final map = (value as Map).cast<String, Object?>();
    final minutes = map['remindMinutes'] as int?;
    if (minutes != null && (minutes < 1 || minutes > 43200)) {
      throw const FormatException('Invalid confirmation reminder');
    }
    return AssignmentSettings(
      required: map['required'] as bool? ?? false,
      remindMinutes: minutes,
    );
  }

  final bool required;
  final int? remindMinutes;
  Map<String, Object?> toJson() => {
    'required': required,
    'remindMinutes': remindMinutes,
  };
}

enum AssignmentKind { task, bring, pick }

enum AssignmentDecision { accepted, declined }

String _digest(Object? value) => base64UrlEncode(
  const DartSha256().hashSync(utf8.encode(jsonEncode(value))).bytes,
).replaceAll('=', '');

Object? _canonical(Object? value) => switch (value) {
  final Map map => {
    for (final key in map.keys.cast<String>().toList()..sort())
      key: _canonical(map[key]),
  },
  final List list => [for (final item in list) _canonical(item)],
  _ => value,
};

/// A confirmation refers to a particular assignment and occurrence, not just
/// to an editable record id. Each member writes a separate response.
class AssignmentRequest {
  AssignmentRequest({
    required this.target,
    required this.memberId,
    required this.kind,
    this.occurrence,
    this.deadline,
  });

  final SyncRecord target;
  final String memberId;
  final AssignmentKind kind;
  final DateTime? occurrence;
  final DateTime? deadline;

  late final String id = _digest([
    target.collection,
    target.id,
    memberId,
    kind.name,
    occurrence?.millisecondsSinceEpoch,
  ]);

  late final String fingerprint = _fingerprint();

  String _fingerprint() {
    final keys = target.collection == Collections.tasks
        ? const ['title', 'notes', 'due', 'repeat', 'repeatEvery', 'photos']
        : const [
            'title',
            'start',
            'end',
            'allDay',
            'location',
            'notes',
            'memberIds',
            'recurrence',
            'exceptions',
            'bringerId',
            'pickerId',
          ];
    return _digest(
      _canonical({
        for (final key in keys) key: target.data[key],
        if (target.collection == Collections.tasks)
          'assignees': Task.assigneesIn(target.data)..sort(),
        'occurrence': occurrence?.millisecondsSinceEpoch,
      }),
    );
  }
}

class AssignmentResponse {
  const AssignmentResponse({
    required this.targetCollection,
    required this.targetId,
    required this.memberId,
    required this.kind,
    required this.fingerprint,
    required this.decision,
    this.occurrence,
  });

  factory AssignmentResponse.fromRecord(SyncRecord r) => AssignmentResponse(
    targetCollection: r.data['targetCollection'] as String,
    targetId: r.data['targetId'] as String,
    memberId: r.data['memberId'] as String,
    kind: AssignmentKind.values.byName(r.data['kind'] as String),
    fingerprint: r.data['fingerprint'] as String,
    decision: AssignmentDecision.values.byName(r.data['decision'] as String),
    occurrence: r.data['occurrence'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r.data['occurrence'] as int),
  );

  final String targetCollection, targetId, memberId, fingerprint;
  final AssignmentKind kind;
  final AssignmentDecision decision;
  final DateTime? occurrence;

  Map<String, Object?> toData() => {
    'targetCollection': targetCollection,
    'targetId': targetId,
    'memberId': memberId,
    'kind': kind.name,
    'fingerprint': fingerprint,
    'decision': decision.name,
    'occurrence': occurrence?.millisecondsSinceEpoch,
  };
}

List<AssignmentRequest> assignmentRequests(
  SyncRecord target, {
  DateTime? occurrence,
  String? timeZone,
}) {
  if (target.deleted || !AssignmentSettings.fromData(target.data).required) {
    return [];
  }
  if (target.collection == Collections.tasks) {
    final task = Task.fromRecord(target);
    if (task.done) return [];
    final due = task.due;
    return [
      for (final id in task.assigneeIds)
        AssignmentRequest(
          target: target,
          memberId: id,
          kind: AssignmentKind.task,
          deadline: due == null
              ? null
              : calendarDate(
                  inCalendarZone(due, timeZone, dateOnly: true),
                  due.year,
                  due.month,
                  due.day,
                  23,
                  59,
                ),
        ),
    ];
  }
  if (target.collection != Collections.events) return [];
  final event = CalendarEvent.fromRecord(target).inTimeZone(timeZone);
  if (event.recurrence != null && event.recurrence!.interval < 1) return [];
  final at = occurrence ?? event.start;
  final actual = event
      .occurrencesBetween(at, at.add(const Duration(milliseconds: 1)))
      .where((o) => o.start.isAtSameMomentAs(at))
      .firstOrNull;
  if (actual == null) return [];
  return _eventRequests(target, event, actual);
}

List<AssignmentRequest> assignmentRequestsBetween(
  SyncRecord target,
  DateTime from,
  DateTime to, {
  String? timeZone,
}) {
  if (target.deleted || !AssignmentSettings.fromData(target.data).required) {
    return [];
  }
  if (target.collection == Collections.tasks) {
    return assignmentRequests(target, timeZone: timeZone);
  }
  if (target.collection != Collections.events) return [];
  final event = CalendarEvent.fromRecord(target).inTimeZone(timeZone);
  return [
    for (final occurrence in event.occurrencesBetween(from, to))
      ..._eventRequests(target, event, occurrence),
  ];
}

List<AssignmentRequest> _eventRequests(
  SyncRecord target,
  CalendarEvent event,
  Occurrence actual,
) => [
  if (event.bringerId case final id?)
    AssignmentRequest(
      target: target,
      memberId: id,
      kind: AssignmentKind.bring,
      occurrence: actual.start,
      deadline: actual.start,
    ),
  if (event.pickerId case final id?)
    AssignmentRequest(
      target: target,
      memberId: id,
      kind: AssignmentKind.pick,
      occurrence: actual.start,
      deadline: actual.end,
    ),
];
