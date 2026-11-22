import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/location/location_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Time moves on without a report from the phone: a time window closes or
/// opens, a pause runs out (#576, #577). The family's view follows the
/// clock, in the family's time zone.
void main() {
  late FamioServerApp app;
  late FamilyMember parent, teen;
  late LocationService service;
  late tz.Location berlin;
  late tz.TZDateTime now;

  const home = (53.5600, 9.9800);
  final weekdays = LocationSchedule(
    weekdays: [1, 2, 3, 4, 5],
    startMinute: 8 * 60,
    endMinute: 16 * 60,
  );

  setUp(() {
    // Also loads the time zones.
    app = FamioServerApp.inMemory();
    berlin = tz.getLocation('Europe/Berlin');
    parent = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    teen = app.accounts.create(
      username: 'teen',
      displayName: 'Teen',
      role: MemberRole.child,
    );
    // Tuesday 10 Nov 2026, 15:50 in Berlin.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 15, 50);
    service = LocationService(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      onChanged: () {},
      clock: () => now,
    );
    app.records.writeAsServer([
      SyncRecord(
        collection: Collections.places,
        id: 'home',
        data: Place(
          id: 'home',
          name: 'Zuhause',
          latitude: home.$1,
          longitude: home.$2,
          notifyMemberIds: [parent.id],
        ).toData(),
        updatedAt: 0,
      ),
    ]);
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  LocationFix fixAt(tz.TZDateTime when, {int? battery}) => LocationFix(
    latitude: home.$1,
    longitude: home.$2,
    accuracy: 15,
    at: when.toUtc(),
    battery: battery,
  );

  MemberLocation? locationOf(String id) {
    final r = app.records.get(Collections.memberLocations, id);
    return r == null || r.deleted ? null : MemberLocation.fromRecord(r);
  }

  int storedPoints() =>
      app.db.select(
            'SELECT count(*) AS n FROM location_points WHERE member_id = ?',
            [teen.id],
          ).first['n']
          as int;

  test('the window closing hides position, place and battery at once', () {
    service.setSchedule(teen.id, weekdays);
    service.report(teen, fixes: [fixAt(now, battery: 70)], device: 'Pixel');
    final shared = locationOf(teen.id)!;
    expect(shared.state, SharingState.active);
    expect(shared.placeId, 'home');
    expect(shared.battery, 70);

    // 15:59: still inside the window, nothing changes.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 15, 59);
    expect(service.followClock(), isFalse);
    // 16:00 the window ends; the phone (an iPhone lying still) sends
    // nothing more.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 16);
    expect(service.followClock(), isTrue);
    final hidden = locationOf(teen.id)!;
    expect(hidden.state, SharingState.scheduled);
    expect(hidden.hasPosition, isFalse);
    expect(hidden.at, isNull);
    expect(hidden.placeId, isNull);
    expect(hidden.battery, isNull);
    expect(hidden.device, isNull);
    expect(hidden.lastContact, isNull);
    expect(service.followClock(), isFalse, reason: 'nothing left to hide');

    // Wednesday 08:00 the window opens: sharing again, but no old position
    // shows up before the phone sends a new one.
    now = tz.TZDateTime(berlin, 2026, 11, 11, 8);
    expect(service.followClock(), isTrue);
    final open = locationOf(teen.id)!;
    expect(open.state, SharingState.active);
    expect(open.hasPosition, isFalse);
    expect(open.placeId, isNull);
    expect(
      open.lastContact?.millisecondsSinceEpoch,
      tz.TZDateTime(berlin, 2026, 11, 10, 15, 50).millisecondsSinceEpoch,
    );
  });

  test('the window follows the family wall clock over the DST nights', () {
    // Sunday 01:00-03:00. 25 Oct 2026 has 02:00-03:00 twice, 28 Mar 2027
    // none.
    service.setSchedule(
      teen.id,
      LocationSchedule(weekdays: [7], startMinute: 60, endMinute: 180),
    );
    SharingState stateAt(tz.TZDateTime at) {
      now = at;
      service.followClock();
      return locationOf(teen.id)!.state;
    }

    now = tz.TZDateTime(berlin, 2026, 10, 25, 1, 30);
    service.report(teen, fixes: [fixAt(now)]);
    expect(locationOf(teen.id)!.state, SharingState.active);
    // The first 02:30 (summer time) and the second one (winter time).
    expect(
      stateAt(tz.TZDateTime.from(DateTime.utc(2026, 10, 25, 0, 30), berlin)),
      SharingState.active,
    );
    expect(
      stateAt(tz.TZDateTime.from(DateTime.utc(2026, 10, 25, 1, 59), berlin)),
      SharingState.active,
    );
    expect(
      stateAt(tz.TZDateTime(berlin, 2026, 10, 25, 3)),
      SharingState.scheduled,
    );

    now = tz.TZDateTime(berlin, 2027, 3, 28, 1, 30);
    service.report(teen, fixes: [fixAt(now)]);
    expect(locationOf(teen.id)!.state, SharingState.active);
    // 02:00 does not exist: 01:59 winter time is followed by 03:00.
    expect(
      stateAt(tz.TZDateTime.from(DateTime.utc(2027, 3, 28, 0, 59), berlin)),
      SharingState.active,
    );
    expect(
      stateAt(tz.TZDateTime(berlin, 2027, 3, 28, 3)),
      SharingState.scheduled,
    );
  });

  test('positions are judged by the wall clock when they were measured', () {
    // Kept from before: the window applies to the time of measurement,
    // also on the DST nights.
    service.setSchedule(
      teen.id,
      LocationSchedule(weekdays: [7], startMinute: 60, endMinute: 180),
    );
    bool stored(tz.TZDateTime at) {
      now = at.add(const Duration(minutes: 1));
      final before = storedPoints();
      service.report(teen, fixes: [fixAt(at)]);
      return storedPoints() > before;
    }

    expect(
      [
        stored(tz.TZDateTime.from(DateTime.utc(2026, 10, 25, 0, 30), berlin)),
        stored(tz.TZDateTime.from(DateTime.utc(2026, 10, 25, 1, 30), berlin)),
        stored(tz.TZDateTime(berlin, 2026, 10, 25, 3, 5)),
        stored(tz.TZDateTime(berlin, 2027, 3, 28, 1, 30)),
        stored(tz.TZDateTime(berlin, 2027, 3, 28, 3, 10)),
      ],
      [true, true, false, true, false],
    );
  });

  test('a phone that stopped outside its window is told silent once', () {
    service.setSchedule(teen.id, weekdays);
    service.report(teen, fixes: [fixAt(now)]);
    // 16:30: one report outside the window, then Famio stops on the phone.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 16, 30);
    service.report(teen, fixes: [fixAt(now)]);
    expect(locationOf(teen.id)!.state, SharingState.scheduled);

    // Thursday 16:30, two days later: outside the window nobody is told.
    now = tz.TZDateTime(berlin, 2026, 11, 12, 16, 30);
    expect(service.newlySilent(now: now), isEmpty);
    // Friday 08:00 the window opens: silent since Tuesday 16:30.
    now = tz.TZDateTime(berlin, 2026, 11, 13, 8);
    final silent = service.newlySilent(now: now);
    expect([for (final (m, _) in silent) m.id], [teen.id]);
    expect(
      silent.single.$2.millisecondsSinceEpoch,
      tz.TZDateTime(berlin, 2026, 11, 10, 16, 30).millisecondsSinceEpoch,
    );
    // Told once: not again when the window closes and opens again.
    now = tz.TZDateTime(berlin, 2026, 11, 13, 17);
    expect(service.newlySilent(now: now), isEmpty);
    now = tz.TZDateTime(berlin, 2026, 11, 16, 8);
    expect(service.newlySilent(now: now), isEmpty);
    // A report ends the silence.
    now = tz.TZDateTime(berlin, 2026, 11, 16, 9);
    service.report(teen, fixes: [fixAt(now)]);
    expect(service.newlySilent(now: now), isEmpty);
  });

  test('a pause that ran out ends without a report', () {
    service.report(teen, fixes: [fixAt(now)]);
    service.pause(
      teen.id,
      duration: const Duration(hours: 1),
      byMember: parent.id,
    );
    expect(locationOf(teen.id)!.state, SharingState.paused);

    now = tz.TZDateTime(berlin, 2026, 11, 10, 16, 49);
    expect(service.followClock(), isFalse);
    expect(locationOf(teen.id)!.state, SharingState.paused);
    now = tz.TZDateTime(berlin, 2026, 11, 10, 16, 50);
    expect(service.followClock(), isTrue);
    final over = locationOf(teen.id)!;
    expect(over.state, SharingState.active);
    expect(over.pausedUntil, isNull);
    expect(service.isPaused(teen.id), isFalse);

    // The pause ended at its end: what the phone measured then and sends
    // later stays private, what came after counts.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 18);
    service.report(
      teen,
      fixes: [
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 16, 20)),
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 17)),
      ],
    );
    expect(storedPoints(), 2, reason: '15:50 and 17:00, not 16:20');
  });

  test('a pause outside the window shows no position either', () {
    service.setSchedule(teen.id, weekdays);
    service.report(teen, fixes: [fixAt(now, battery: 70)]);
    service.pause(
      teen.id,
      duration: const Duration(hours: 3),
      byMember: parent.id,
    );
    final paused = locationOf(teen.id)!;
    expect(paused.state, SharingState.paused);
    expect(paused.hasPosition, isTrue, reason: 'as before the pause');

    now = tz.TZDateTime(berlin, 2026, 11, 10, 16);
    expect(service.followClock(), isTrue);
    final hidden = locationOf(teen.id)!;
    expect(hidden.state, SharingState.paused);
    expect(hidden.pausedUntil, paused.pausedUntil);
    expect(hidden.hasPosition, isFalse);
    expect(hidden.placeId, isNull);
    expect(hidden.battery, isNull);
    // A report while paused outside the window shows nothing either.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 16, 10);
    expect(service.report(teen, fixes: const []).paused, isTrue);
    expect(locationOf(teen.id)!.hasPosition, isFalse);
    // The pause ends outside the window: off by the schedule.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 18, 50);
    expect(service.followClock(), isTrue);
    expect(locationOf(teen.id)!.state, SharingState.scheduled);
  });

  test('a phone that stopped during a pause is silent after it', () {
    service.report(teen, fixes: [fixAt(now)]);
    service.pause(
      teen.id,
      duration: const Duration(hours: 1),
      byMember: parent.id,
    );
    // Three days later; the hourly check ends the pause first.
    now = now.add(const Duration(days: 3));
    final silent = service.newlySilent(now: now);
    expect([for (final (m, _) in silent) m.id], [teen.id]);
    expect(locationOf(teen.id)!.state, SharingState.active);
    expect(service.newlySilent(now: now), isEmpty, reason: 'told once');
  });

  test('a stored window the server cannot read shares nothing', () {
    for (final broken in ['{broken', '[1,2]', '{"weekdays":[]}']) {
      app.db.execute(
        'INSERT INTO location_state (member_id, sharing_schedule)'
        ' VALUES (?, ?) ON CONFLICT(member_id) DO UPDATE SET'
        ' sharing_schedule = excluded.sharing_schedule',
        [teen.id, broken],
      );
      expect(service.scheduleFor(teen.id), isNull, reason: broken);
      now = now.add(const Duration(minutes: 3));
      final result = service.report(teen, fixes: [fixAt(now)]);
      expect(result.paused, isFalse, reason: broken);
      expect(storedPoints(), 0, reason: broken);
      final l = locationOf(teen.id)!;
      expect(l.state, SharingState.scheduled, reason: broken);
      expect(l.hasPosition, isFalse, reason: broken);
      expect(service.followClock(), isFalse, reason: broken);
    }
  });
}
