part of 'record_store.dart';

extension RecordAssignments on RecordStore {
  List<AssignmentRequest> assignmentRequestsFor(
    SyncRecord target, {
    DateTime? occurrence,
  }) => assignmentRequests(
    target,
    occurrence: occurrence,
    timeZone: assignmentLocation?.call().name,
  );

  List<AssignmentRequest> assignmentRequestsDue(
    SyncRecord target,
    DateTime from,
    DateTime to,
  ) {
    return assignmentRequestsBetween(
      target,
      from,
      to,
      timeZone: assignmentLocation?.call().name,
    );
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
