import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/family/repeating_tasks.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Points, chores, routines, repeating tasks and pocket money (#581).
void main() {
  late FamioServerApp app;
  late FamilyMember mama, kid, sibling;
  late Map<String, String> tokens;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    kid = app.accounts.create(
      username: 'kid',
      displayName: 'Kid',
      role: MemberRole.child,
    );
    sibling = app.accounts.create(
      username: 'sib',
      displayName: 'Sib',
      role: MemberRole.child,
    );
    tokens = {
      for (final m in [mama, kid, sibling])
        m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<SyncResponse> sync(
    FamilyMember who, [
    List<SyncRecord> changes = const [],
  ]) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(SyncRequest(since: 0, changes: changes).toJson()),
      ),
    );
    expect(r.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    );
  }

  SyncRecord rec(
    String collection,
    String id,
    Map<String, Object?> data, {
    bool deleted = false,
  }) => SyncRecord(
    collection: collection,
    id: id,
    data: data,
    deleted: deleted,
    updatedAt: clock += 1000,
    rev: app.records.get(collection, id)?.rev ?? 0,
  );

  group('a declined chore', () {
    const id = 'c-chore1-2026-11-10';
    PointEntry entry(FamilyMember who, PointStatus status) => PointEntry(
      id: id,
      memberId: who.id,
      points: 2,
      title: 'Spülmaschine',
      kind: PointKind.chore,
      at: DateTime.now(),
      refId: 'chore1',
      status: status,
    );
    Future<void> declined(FamilyMember who) async {
      await sync(who, [
        rec(
          Collections.pointEntries,
          id,
          entry(who, PointStatus.pending).toData(),
        ),
      ]);
      await sync(mama, [
        rec(
          Collections.pointEntries,
          id,
          entry(
            who,
            PointStatus.pending,
          ).decide(PointStatus.rejected, mama.id).toData(),
        ),
      ]);
    }

    PointEntry stored() =>
        PointEntry.fromRecord(app.records.get(Collections.pointEntries, id)!);

    test('its child asks for it again', () async {
      await declined(kid);
      final again = await sync(kid, [
        rec(
          Collections.pointEntries,
          id,
          entry(kid, PointStatus.pending).toData(),
        ),
      ]);
      expect(again.refused, isEmpty);
      expect(stored().status, PointStatus.pending);
      // Only adults confirm it.
      final approve = await sync(kid, [
        rec(
          Collections.pointEntries,
          id,
          entry(kid, PointStatus.approved).toData(),
        ),
      ]);
      expect(approve.refused.single.id, id);
      expect(stored().status, PointStatus.pending);
    });

    test('its child takes it back', () async {
      await declined(kid);
      final back = await sync(kid, [
        rec(Collections.pointEntries, id, const {}, deleted: true),
      ]);
      expect(back.refused, isEmpty);
      expect(app.records.get(Collections.pointEntries, id)!.deleted, isTrue);
    });

    test('a sibling neither asks for it nor takes it back', () async {
      await declined(sibling);
      final mine = await sync(kid, [
        rec(
          Collections.pointEntries,
          id,
          entry(kid, PointStatus.pending).toData(),
        ),
      ]);
      final gone = await sync(kid, [
        rec(Collections.pointEntries, id, const {}, deleted: true),
      ]);
      expect(mine.refused.single.id, id);
      expect(gone.refused.single.id, id);
      expect(stored().status, PointStatus.rejected);
      expect(stored().memberId, sibling.id);
    });
  });

  test('a child ticks off only its own routines', () async {
    RoutineRun run(FamilyMember who, Set<String> done) => RoutineRun(
      id: 'rr-morning-2026-11-10-${who.id.substring(0, 8)}',
      routineId: 'morning',
      memberId: who.id,
      day: DateTime(2026, 11, 10),
      done: done,
    );
    final theirs = run(sibling, const {'teeth', 'dress'});
    await sync(sibling, [
      rec(Collections.routineRuns, theirs.id, theirs.toData()),
    ]);
    final r = await sync(kid, [
      rec(Collections.routineRuns, theirs.id, run(sibling, const {}).toData()),
      rec(Collections.routineRuns, theirs.id, const {}, deleted: true),
    ]);
    expect(r.refused.map((i) => i.id), [theirs.id, theirs.id]);
    final stored = app.records.get(Collections.routineRuns, theirs.id)!;
    expect(stored.deleted, isFalse);
    expect(RoutineRun.fromRecord(stored).done, {'teeth', 'dress'});

    final own = run(kid, const {'teeth'});
    final ok = await sync(kid, [
      rec(Collections.routineRuns, own.id, own.toData()),
    ]);
    expect(ok.refused, isEmpty);
    // Nor does it pass its own run off as a sibling's.
    final passed = await sync(kid, [
      rec(Collections.routineRuns, own.id, {
        ...own.toData(),
        'memberId': sibling.id,
      }),
    ]);
    expect(passed.refused.single.id, own.id);
  });

  // The family's zone is not the server's here (New York, the clocks change
  // on another day than in Europe; or a server in UTC).
  for (final (zone, before, after) in [
    ('America/New_York', DateTime(2027, 3, 13), DateTime(2027, 3, 20)),
    ('Europe/Berlin', DateTime(2027, 3, 27), DateTime(2027, 4, 3)),
  ]) {
    test('the server moves a repeating task on in the family zone ($zone)', () {
      final location = tz.getLocation(zone);
      final remind = tz.TZDateTime(
        location,
        before.year,
        before.month,
        before.day,
        18,
      );
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.tasks,
          id: 't1',
          data: {
            'title': 'Müll rausbringen',
            'done': true,
            'due': before.toIso8601String(),
            'remindAt': remind.toUtc().toIso8601String(),
            'repeat': 'weekly',
            'repeatEvery': 1,
            'assigneeId': null,
          },
          updatedAt: 0,
        ),
      ]);
      advanceRepeatingTasks(app.records, ['t1'], location: location);
      final t = Task.fromRecord(app.records.get(Collections.tasks, 't1')!);
      expect(t.done, isFalse);
      expect(t.due, after);
      final local = tz.TZDateTime.from(t.remindAt!, location);
      expect(
        (local.month, local.day, local.hour, local.minute),
        (after.month, after.day, 18, 0),
      );
    });
  }

  group('pocket money on holiday', () {
    // The time zone data is there once the app is set up.
    tz.Location berlin() => tz.getLocation('Europe/Berlin');
    void allowanceAndHoliday({required DateTime from, required DateTime to}) {
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.allowances,
          id: kid.id,
          data: Allowance(
            memberId: kid.id,
            weeklyCents: 500,
            payday: DateTime.saturday,
            since: DateTime(2026, 10, 1),
          ).toData(),
          updatedAt: 0,
        ),
        SyncRecord(
          collection: Collections.vacations,
          id: 'v1',
          data: Vacation(
            id: 'v1',
            from: from,
            to: to,
            allowance: true,
          ).toData(),
          updatedAt: 0,
        ),
      ]);
    }

    void deleteHoliday() => app.records.writeAsServer([
      SyncRecord(
        collection: Collections.vacations,
        id: 'v1',
        data: const {},
        deleted: true,
        updatedAt: 0,
      ),
    ]);

    List<String> booked() => [
      for (final r in app.records.all(Collections.moneyEntries))
        r.id.substring(r.id.length - 10),
    ]..sort();

    test('deleting a running holiday pays no paused payday', () {
      allowanceAndHoliday(
        from: DateTime(2026, 10, 24),
        to: DateTime(2026, 11, 20),
      );
      final first = app.allowances.run(
        now: tz.TZDateTime(berlin(), 2026, 11, 12, 9),
      );
      expect(first, 3);
      // Back early: an adult deletes the holiday before it ends.
      deleteHoliday();
      final second = app.allowances.run(
        now: tz.TZDateTime(berlin(), 2026, 11, 12, 10),
      );
      expect(second, 0);
      expect(booked(), ['2026-10-03', '2026-10-10', '2026-10-17']);
    });

    test('a holiday deleted before a payday still pays it', () {
      allowanceAndHoliday(
        from: DateTime(2026, 11, 20),
        to: DateTime(2026, 11, 30),
      );
      app.allowances.run(now: tz.TZDateTime(berlin(), 2026, 11, 14, 9));
      deleteHoliday();
      expect(
        app.allowances.run(now: tz.TZDateTime(berlin(), 2026, 11, 21, 9)),
        1,
      );
      expect(booked().last, '2026-11-21');
    });

    test('bookings carry no German note, the apps name the kind', () {
      allowanceAndHoliday(
        from: DateTime(2026, 12, 20),
        to: DateTime(2026, 12, 30),
      );
      app.allowances.run(now: tz.TZDateTime(berlin(), 2026, 10, 3, 9));
      final entry = MoneyEntry.fromRecord(
        app.records.all(Collections.moneyEntries).single,
      );
      expect((entry.kind, entry.note), (MoneyKind.allowance, ''));
    });
  });
}
