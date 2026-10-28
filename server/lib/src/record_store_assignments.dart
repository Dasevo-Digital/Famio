part of 'record_store.dart';

extension RecordAssignments on RecordStore {
  /// Validates calendar dates in the family's zone, independently of the
  /// host's local zone. Responses still refer to absolute instants.
  List<AssignmentRequest> assignmentRequestsFor(
    SyncRecord target, {
    DateTime? occurrence,
  }) {
    final zone = assignmentLocation?.call();
    if (zone == null) return assignmentRequests(target, occurrence: occurrence);
    if (target.deleted || !AssignmentSettings.fromData(target.data).required) {
      return [];
    }
    if (target.collection == Collections.tasks) {
      return [
        for (final r in assignmentRequests(target))
          AssignmentRequest(
            target: target,
            memberId: r.memberId,
            kind: r.kind,
            deadline: r.deadline == null
                ? null
                : tz.TZDateTime(
                    zone,
                    r.deadline!.year,
                    r.deadline!.month,
                    r.deadline!.day,
                    23,
                    59,
                  ),
          ),
      ];
    }
    if (target.collection != Collections.events) return [];
    final event = CalendarEvent.fromRecord(target);
    final start = tz.TZDateTime.from(event.start, zone);
    final at = tz.TZDateTime.from(occurrence ?? event.start, zone);
    final rule = event.recurrence;
    if (rule == null) {
      if (!at.isAtSameMomentAs(start)) return [];
    } else {
      if (rule.interval < 1) return [];
      final expected = tz.TZDateTime(
        zone,
        at.year,
        at.month,
        at.day,
        start.hour,
        start.minute,
        start.second,
        start.millisecond,
        start.microsecond,
      );
      if (!at.isAtSameMomentAs(expected) || at.isBefore(start)) return [];
      final day = DateTime.utc(at.year, at.month, at.day);
      final firstDay = DateTime.utc(start.year, start.month, start.day);
      final days = day.difference(firstDay).inDays;
      final matches = switch (rule.frequency) {
        RecurrenceFrequency.daily => days % rule.interval == 0,
        RecurrenceFrequency.weekly =>
          (days + start.weekday - 1) ~/ 7 % rule.interval == 0 &&
              (rule.weekdays.isEmpty
                  ? at.weekday == start.weekday
                  : rule.weekdays.contains(at.weekday)),
        RecurrenceFrequency.monthly =>
          at.day == start.day &&
              ((at.year - start.year) * 12 + at.month - start.month) %
                      rule.interval ==
                  0,
        RecurrenceFrequency.yearly =>
          at.day == start.day &&
              at.month == start.month &&
              (at.year - start.year) % rule.interval == 0,
      };
      if (!matches) return [];
      if (rule.until case final until?) {
        if (day.isAfter(DateTime.utc(until.year, until.month, until.day))) {
          return [];
        }
      }
      if (event.exceptions.any(
        (e) => e.year == at.year && e.month == at.month && e.day == at.day,
      )) {
        return [];
      }
    }
    return [
      if (event.bringerId case final id?)
        AssignmentRequest(
          target: target,
          memberId: id,
          kind: AssignmentKind.bring,
          occurrence: at,
          deadline: at,
        ),
      if (event.pickerId case final id?)
        AssignmentRequest(
          target: target,
          memberId: id,
          kind: AssignmentKind.pick,
          occurrence: at,
          deadline: at.add(event.duration),
        ),
    ];
  }

  List<AssignmentRequest> assignmentRequestsDue(
    SyncRecord target,
    DateTime from,
    DateTime to,
  ) {
    final zone = assignmentLocation?.call();
    if (target.collection == Collections.tasks) {
      return assignmentRequestsFor(target);
    }
    if (zone == null) {
      return [
        for (final o in CalendarEvent.fromRecord(
          target,
        ).occurrencesBetween(from, to))
          ...assignmentRequestsFor(target, occurrence: o.start),
      ];
    }
    final event = CalendarEvent.fromRecord(target);
    final start = tz.TZDateTime.from(event.start, zone);
    final found = <String, AssignmentRequest>{};
    for (final kind in [AssignmentKind.bring, AssignmentKind.pick]) {
      final shift = kind == AssignmentKind.pick
          ? event.duration
          : Duration.zero;
      final first = tz.TZDateTime.from(from.subtract(shift), zone);
      final end = tz.TZDateTime.from(to.subtract(shift), zone);
      var day = DateTime.utc(first.year, first.month, first.day);
      final last = DateTime.utc(end.year, end.month, end.day);
      while (!day.isAfter(last)) {
        final at = tz.TZDateTime(
          zone,
          day.year,
          day.month,
          day.day,
          start.hour,
          start.minute,
          start.second,
          start.millisecond,
          start.microsecond,
        );
        for (final request in assignmentRequestsFor(target, occurrence: at)) {
          if (request.kind == kind &&
              !request.deadline!.isBefore(from) &&
              !request.deadline!.isAfter(to)) {
            found[request.id] = request;
          }
        }
        day = day.add(const Duration(days: 1));
      }
    }
    return found.values.toList();
  }

  SyncRecord? _assignmentTarget(SyncRecord response) => _get(
    response.data['targetCollection'] as String,
    response.data['targetId'] as String,
  );

  AssignmentRequest? _requestFor(SyncRecord response) {
    final parent = _assignmentTarget(response);
    if (parent == null || !recordDataIsValid(parent)) return null;
    final reply = AssignmentResponse.fromRecord(response);
    return assignmentRequestsFor(parent, occurrence: reply.occurrence)
        .where(
          (a) =>
              a.id == response.id &&
              a.memberId == reply.memberId &&
              a.kind == reply.kind &&
              a.fingerprint == reply.fingerprint,
        )
        .firstOrNull;
  }

  bool _validAssignmentReply(SyncRecord incoming, String memberId) {
    if (incoming.deleted) {
      final old = _get(incoming.collection, incoming.id);
      return old != null && old.data['memberId'] == memberId;
    }
    final request = _requestFor(incoming);
    return request != null &&
        request.memberId == memberId &&
        canAccess(request.target, memberId);
  }

  List<String> _assignmentAudience(SyncRecord target) => [
    for (final id in memberIds())
      if (canAccess(target, id)) id,
  ];

  void _assignmentsFollow(SyncRecord target) {
    if (target.collection != Collections.tasks &&
        target.collection != Collections.events) {
      return;
    }
    for (final row in _db.select(
      'SELECT * FROM records WHERE collection = ? AND deleted = 0 '
      "AND json_extract(data, '\$.targetCollection') = ? AND json_extract(data, '\$.targetId') = ?",
      [Collections.assignmentResponses, target.collection, target.id],
    )) {
      final old = RecordStore._record(row);
      final current = _requestFor(old);
      final audience = _assignmentAudience(target);
      final valid =
          !target.deleted &&
          current != null &&
          audience.contains(old.data['memberId']);
      final data = valid
          ? {...old.data, SyncRecord.visibilityKey: audience}
          : <String, Object?>{
              if (old.visibleTo != null)
                SyncRecord.visibilityKey: old.visibleTo,
            };
      if (valid && jsonEncode(old.visibleTo) == jsonEncode(audience)) continue;
      _put(
        old.copyWith(
          data: data,
          deleted: !valid,
          updatedAt: valid
              ? old.updatedAt
              : max(DateTime.now().millisecondsSinceEpoch, old.updatedAt + 1),
          updatedBy: valid ? old.updatedBy : RecordStore.serverMemberId,
        ),
        previous: old,
      );
    }
  }
}
