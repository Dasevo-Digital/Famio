import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember owner, first, second;

  test(
    'family-zone validation respects weekly, monthly and yearly series boundaries',
    () {
      final cases = [
        (
          DateTime.utc(2027, 3, 1, 9),
          const Recurrence(
            RecurrenceFrequency.weekly,
            interval: 2,
            weekdays: [2, 4],
          ),
          DateTime.utc(2027, 3, 16, 9),
          DateTime.utc(2027, 3, 9, 9),
        ),
        (
          DateTime.utc(2027, 1, 31, 9),
          Recurrence(RecurrenceFrequency.monthly, until: DateTime(2027, 3, 31)),
          DateTime.utc(2027, 3, 31, 8),
          DateTime.utc(2027, 5, 31, 8),
        ),
        (
          DateTime.utc(2028, 2, 29, 9),
          const Recurrence(RecurrenceFrequency.yearly),
          DateTime.utc(2032, 2, 29, 9),
          DateTime.utc(2029, 2, 28, 9),
        ),
      ];
      for (final (start, rule, valid, invalid) in cases) {
        final event = CalendarEvent(
          id: 'event',
          title: 'Lift',
          start: start,
          end: start.add(const Duration(hours: 1)),
          recurrence: rule,
          bringerId: first.id,
          assignmentConfirmation: const AssignmentSettings(required: true),
        );
        SyncRecord record(CalendarEvent value) => SyncRecord(
          collection: Collections.events,
          id: value.id,
          data: value.toData(),
          updatedAt: 1,
        );
        expect(
          app.records.assignmentRequestsFor(record(event), occurrence: valid),
          hasLength(1),
        );
        expect(
          app.records.assignmentRequestsFor(record(event), occurrence: invalid),
          isEmpty,
        );
        final excluded = event.copyWith(
          exceptions: {DateTime(valid.year, valid.month, valid.day)},
        );
        expect(
          app.records.assignmentRequestsFor(
            record(excluded),
            occurrence: valid,
          ),
          isEmpty,
        );
      }
    },
  );
  setUp(() {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
    first = app.accounts.create(username: 'first', displayName: 'First');
    second = app.accounts.create(username: 'second', displayName: 'Second');
  });
  tearDown(() async {
    await app.push.idle;
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });
  SyncRecord task({
    String title = 'Help',
    List<String>? audience,
    int? reminder,
    DateTime? due,
  }) {
    final current = app.records.get(Collections.tasks, 'task');
    app.records.writeAs(owner.id, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'task',
        updatedAt: (current?.updatedAt ?? 0) + 1,
        data: Task(
          id: 'task',
          title: title,
          assigneeIds: [first.id, second.id],
          visibleTo: audience,
          due: due,
          assignmentConfirmation: AssignmentSettings(
            required: true,
            remindMinutes: reminder,
          ),
        ).toData(),
      ),
    ]);
    return app.records.get(Collections.tasks, 'task')!;
  }

  SyncRecord response(
    AssignmentRequest r, {
    String? who,
    String? fingerprint,
    String? id,
    AssignmentDecision decision = AssignmentDecision.accepted,
  }) => SyncRecord(
    collection: Collections.assignmentResponses,
    id: id ?? r.id,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    data: AssignmentResponse(
      targetCollection: r.target.collection,
      targetId: r.target.id,
      memberId: who ?? r.memberId,
      kind: r.kind,
      fingerprint: fingerprint ?? r.fingerprint,
      decision: decision,
      occurrence: r.occurrence,
    ).toData(),
  );

  test(
    'each assignee responds independently and cannot impersonate another',
    () {
      final requests = assignmentRequests(task());
      expect(app.records.writeAs(first.id, [response(requests[0])]), isEmpty);
      expect(
        app.records.writeAs(second.id, [
          response(requests[1], decision: AssignmentDecision.declined),
        ]),
        isEmpty,
      );
      expect(app.records.all(Collections.assignmentResponses), hasLength(2));
      final forged = app.records.writeAs(first.id, [response(requests[1])]);
      expect(forged.single.deleted, isTrue);
      expect(
        app.records
            .get(Collections.assignmentResponses, requests[1].id)!
            .data['decision'],
        'declined',
      );
      expect(
        app.records
            .writeAs(first.id, [response(requests[0], id: 'forged')])
            .single
            .deleted,
        isTrue,
      );
    },
  );

  test(
    'an edited assignment invalidates old approvals and rejects their offline replay',
    () {
      final old = assignmentRequests(task()).first;
      app.records.writeAs(first.id, [response(old)]);
      task(title: 'Changed');
      expect(
        app.records.get(Collections.assignmentResponses, old.id)!.deleted,
        isTrue,
      );
      expect(
        app.records.writeAs(first.id, [response(old)]).single.deleted,
        isTrue,
      );
      final current = assignmentRequests(
        app.records.get(Collections.tasks, 'task')!,
      ).first;
      expect(current.fingerprint, isNot(old.fingerprint));
      expect(app.records.writeAs(first.id, [response(current)]), isEmpty);
      expect(
        app.records.get(Collections.assignmentResponses, current.id)!.deleted,
        isFalse,
      );
    },
  );

  test('older clients retain the confirmation setting when editing a task', () {
    final existing = task();
    app.records.writeAs(owner.id, [
      existing.copyWith(
        updatedAt: existing.updatedAt + 1,
        data: {...existing.data}..remove('assignmentConfirmation'),
      ),
    ]);
    expect(
      AssignmentSettings.fromData(
        app.records.get(Collections.tasks, 'task')!.data,
      ).required,
      isTrue,
    );
  });

  test('changing visibility alone does not overwrite a queued response', () {
    final request = assignmentRequests(task()).first;
    app.records.writeAs(first.id, [response(request).copyWith(updatedAt: 1)]);
    final target = app.records.get(Collections.tasks, 'task')!;
    app.records.writeAs(owner.id, [
      target.copyWith(
        updatedAt: target.updatedAt + 1,
        data: {
          ...target.data,
          'visibleTo': [owner.id, first.id, second.id],
        },
      ),
    ]);
    final queued = response(
      request,
      decision: AssignmentDecision.declined,
    ).copyWith(updatedAt: 2);
    expect(app.records.writeAs(first.id, [queued]), isEmpty);
    expect(
      app.records
          .get(Collections.assignmentResponses, request.id)!
          .data['decision'],
      'declined',
    );
  });

  test(
    'guest replies need a visible assignment and privacy changes remove old replies',
    () {
      app.accounts.update(first.id, role: MemberRole.guest);
      final request = assignmentRequests(
        task(audience: [owner.id, first.id, second.id]),
      ).first;
      expect(app.records.writeAs(first.id, [response(request)]), isEmpty);
      final before = app.records.currentRev;
      final target = app.records.get(Collections.tasks, 'task')!;
      app.records.writeAs(owner.id, [
        target.copyWith(
          updatedAt: target.updatedAt + 1,
          data: Task(
            id: 'task',
            title: 'Help',
            assigneeIds: [second.id],
            visibleTo: [owner.id, second.id],
            assignmentConfirmation: const AssignmentSettings(required: true),
          ).toData(),
        ),
      ]);
      final revoked = app.records.sync(SyncRequest(since: before), first.id);
      expect(
        revoked.changes.any(
          (r) => r.collection == Collections.assignmentResponses && r.deleted,
        ),
        isTrue,
      );
      expect(
        app.records.writeAs(first.id, [response(request)]).single.deleted,
        isTrue,
      );
    },
  );

  test(
    'a role downgrade cannot expose replies of a task the guest no longer receives',
    () {
      final request = assignmentRequests(
        task(audience: [owner.id, first.id, second.id]),
      ).first;
      app.records.writeAs(first.id, [response(request)]);
      final observer = app.accounts.create(
        username: 'observer',
        displayName: 'Observer',
      );
      final parent = app.records.get(Collections.tasks, 'task')!;
      app.records.writeAs(owner.id, [
        parent.copyWith(
          updatedAt: parent.updatedAt + 1,
          data: {...parent.data, 'visibleTo': null},
        ),
      ]);
      expect(
        app.records
            .sync(const SyncRequest(since: 0), observer.id)
            .changes
            .any(
              (r) =>
                  r.collection == Collections.assignmentResponses && !r.deleted,
            ),
        isTrue,
      );
      app.accounts.update(observer.id, role: MemberRole.guest);
      expect(
        app.records
            .sync(const SyncRequest(since: 0), observer.id)
            .changes
            .any(
              (r) =>
                  r.collection == Collections.assignmentResponses && !r.deleted,
            ),
        isFalse,
      );
    },
  );

  test(
    'recurring lifts require separate responses for each occurrence and direction',
    () {
      final start = DateTime(2027, 3, 1, 10);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.events,
          id: 'event',
          updatedAt: 1,
          data: CalendarEvent(
            id: 'event',
            title: 'Training',
            start: start,
            end: start.add(const Duration(hours: 1)),
            recurrence: const Recurrence(RecurrenceFrequency.daily),
            bringerId: first.id,
            pickerId: first.id,
            assignmentConfirmation: const AssignmentSettings(required: true),
          ).toData(),
        ),
      ]);
      final event = app.records.get(Collections.events, 'event')!;
      final today = assignmentRequests(event, occurrence: start);
      final tomorrow = assignmentRequests(
        event,
        occurrence: DateTime(2027, 3, 2, 10),
      );
      expect({
        today[0].id,
        today[1].id,
        tomorrow[0].id,
        tomorrow[1].id,
      }, hasLength(4));
      app.records.writeAs(first.id, [response(today[0])]);
      expect(
        app.records.get(Collections.assignmentResponses, tomorrow[0].id),
        isNull,
      );
      final fake = AssignmentRequest(
        target: event,
        memberId: first.id,
        kind: AssignmentKind.bring,
        occurrence: start.add(const Duration(minutes: 5)),
      );
      expect(
        app.records.writeAs(first.id, [response(fake)]).single.deleted,
        isTrue,
      );
    },
  );

  test(
    'optional reminders are private, deduplicated, and stop after a reply',
    () async {
      final now = DateTime.now();
      final due = DateTime(now.year, now.month, now.day + 1);
      final record = task(
        due: due,
        reminder: 1440,
        audience: [owner.id, first.id, second.id],
      );
      final requests = assignmentRequests(record);
      app.records.writeAs(second.id, [
        response(requests[1], decision: AssignmentDecision.declined),
      ]);
      await app.push.idle;
      final notices = <(List<String>, PushNotice)>[];
      app.push.onNotice = (ids, notice, _) => notices.add((ids, notice));
      final at = requests.first.deadline!.subtract(const Duration(hours: 2));
      app.push.remindAssignments(now: at);
      await app.push.idle;
      expect(notices, hasLength(1));
      expect(notices.single.$1, [first.id]);
      app.push.remindAssignments(now: at.add(const Duration(minutes: 1)));
      await app.push.idle;
      expect(notices, hasLength(1));
      final restarted = PushService(
        db: app.db,
        records: app.records,
        accounts: app.accounts,
        location: () => app.location,
      );
      restarted.onNotice = (ids, notice, _) => notices.add((ids, notice));
      restarted.remindAssignments(now: at.add(const Duration(minutes: 1)));
      await restarted.idle;
      expect(
        notices,
        hasLength(1),
        reason: 'deduplication survives service restarts',
      );
      restarted.close();
      app.records.writeAs(first.id, [response(requests[0])]);
      app.push.remindAssignments(now: at.add(const Duration(minutes: 2)));
      await app.push.idle;
      expect(
        notices,
        hasLength(2),
        reason: 'only the reply notice to the author is new',
      );
    },
  );

  test(
    'cached plans follow new assignments, edits, deletion and withdrawn replies',
    () async {
      final due = DateTime(2027, 5, 4);
      final record = task(due: due, reminder: 1440);
      final requests = app.records.assignmentRequestsFor(record);
      app.records.writeAs(first.id, [response(requests[0])]);
      app.records.writeAs(second.id, [response(requests[1])]);
      await app.push.idle;
      final notices = <PushNotice>[];
      app.push.onNotice = (_, notice, _) {
        if (notice.tag == 'clipboard') notices.add(notice);
      };
      final at = requests.first.deadline!.subtract(const Duration(hours: 1));
      await app.push.remindAssignments(now: at);
      expect(notices, isEmpty);
      final reply = app.records.get(
        Collections.assignmentResponses,
        requests.first.id,
      )!;
      app.records.writeAs(first.id, [
        reply.copyWith(
          deleted: true,
          updatedAt: reply.updatedAt + 1,
          data: const {},
        ),
      ]);
      await app.push.remindAssignments(now: at.add(const Duration(minutes: 1)));
      expect(notices, hasLength(1));
      final changed = task(
        title: 'Changed after planning',
        due: due,
        reminder: 1440,
      );
      await app.push.remindAssignments(now: at.add(const Duration(minutes: 2)));
      expect(notices, hasLength(3));
      app.records.writeAs(owner.id, [
        changed.copyWith(
          deleted: true,
          updatedAt: changed.updatedAt + 1,
          data: const {},
        ),
      ]);
      await app.push.remindAssignments(now: at.add(const Duration(minutes: 3)));
      expect(notices, hasLength(3));
      task(title: 'New assignment', due: due, reminder: 1440);
      await app.push.remindAssignments(now: at.add(const Duration(minutes: 4)));
      expect(notices, hasLength(5));
    },
  );

  test(
    'lift confirmations and reminders follow the family zone over DST',
    () async {
      final start = DateTime.utc(2027, 3, 27, 9);
      final next = DateTime.utc(2027, 3, 28, 8);
      app.records.writeAs(owner.id, [
        SyncRecord(
          collection: Collections.events,
          id: 'event',
          updatedAt: 1,
          data: CalendarEvent(
            id: 'event',
            title: 'Morning lift',
            start: start,
            end: start.add(const Duration(hours: 1)),
            recurrence: const Recurrence(RecurrenceFrequency.daily),
            bringerId: first.id,
            assignmentConfirmation: const AssignmentSettings(
              required: true,
              remindMinutes: 60,
            ),
          ).toData(),
        ),
      ]);
      final event = app.records.get(Collections.events, 'event')!;
      final request = app.records
          .assignmentRequestsFor(event, occurrence: next)
          .single;
      expect(request.deadline!.isAtSameMomentAs(next), isTrue);
      expect(
        app.records.assignmentRequestsFor(
          event,
          occurrence: next.add(const Duration(hours: 1)),
        ),
        isEmpty,
      );
      final notices = <PushNotice>[];
      app.push.onNotice = (_, notice, _) => notices.add(notice);
      app.push.remindAssignments(
        now: next.subtract(const Duration(minutes: 30)),
      );
      await app.push.idle;
      expect(notices, hasLength(1));
      expect(app.records.writeAs(first.id, [response(request)]), isEmpty);
    },
  );
}
