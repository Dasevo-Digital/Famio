// Positions a phone sends late (#398): a pause that ran out ends then, so
// the time until the next pause stays shared; positions measured before
// the schedule changed are dropped, as the schedule of then is not kept.
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/location/location_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  late FamioServerApp app;
  late FamilyMember parent, teen;
  late LocationService service;
  late tz.Location berlin;
  late tz.TZDateTime now;

  setUp(() {
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
    now = tz.TZDateTime(berlin, 2026, 11, 9, 8);
    service = LocationService(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      onChanged: () {},
      clock: () => now,
    );
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  LocationFix at(tz.TZDateTime when) => LocationFix(
    latitude: 53.60,
    longitude: 10.00,
    accuracy: 15,
    at: when.toUtc(),
  );

  List<int> stored() => [
    for (final p in service.history(
      teen.id,
      from: tz.TZDateTime(berlin, 2026, 11, 8),
      to: now.toUtc().add(const Duration(minutes: 1)),
    ))
      p.at.millisecondsSinceEpoch,
  ];

  test('a pause that ran out is not joined to the next one', () {
    // 08:00 paused for an hour; offline from 09:00, nobody reports.
    service.pause(
      teen.id,
      duration: const Duration(hours: 1),
      byMember: parent.id,
    );
    now = tz.TZDateTime(berlin, 2026, 11, 9, 14);
    service.pause(
      teen.id,
      duration: const Duration(hours: 1),
      byMember: parent.id,
    );
    // 18:00 the phone is back with what it measured meanwhile.
    now = tz.TZDateTime(berlin, 2026, 11, 9, 18);
    final shared = tz.TZDateTime(berlin, 2026, 11, 9, 11);
    final pausedFirst = tz.TZDateTime(berlin, 2026, 11, 9, 8, 30);
    final pausedThen = tz.TZDateTime(berlin, 2026, 11, 9, 14, 30);
    service.report(teen, fixes: [at(pausedFirst), at(shared), at(pausedThen)]);
    expect(stored(), [shared.millisecondsSinceEpoch]);
  });

  test('a loosened schedule does not open up what it hid then', () {
    // Weekdays 08–16, then the window is removed the next morning.
    service.setSchedule(
      teen.id,
      LocationSchedule(
        weekdays: [1, 2, 3, 4, 5],
        startMinute: 8 * 60,
        endMinute: 16 * 60,
      ),
    );
    now = tz.TZDateTime(berlin, 2026, 11, 10, 9);
    service.setSchedule(teen.id, null);
    final evening = tz.TZDateTime(berlin, 2026, 11, 9, 21);
    final later = tz.TZDateTime(berlin, 2026, 11, 10, 9, 1);
    now = tz.TZDateTime(berlin, 2026, 11, 10, 9, 2);
    service.report(teen, fixes: [at(evening), at(later)]);
    expect(stored(), [later.millisecondsSinceEpoch]);
  });

  test('positions from before the first schedule stay shared', () {
    now = tz.TZDateTime(berlin, 2026, 11, 10, 9);
    final morning = tz.TZDateTime(berlin, 2026, 11, 10, 8, 30);
    service.setSchedule(
      teen.id,
      LocationSchedule(
        weekdays: [1, 2, 3, 4, 5],
        startMinute: 8 * 60,
        endMinute: 16 * 60,
      ),
    );
    final night = tz.TZDateTime(berlin, 2026, 11, 9, 23);
    service.report(teen, fixes: [at(night), at(morning)]);
    // The evening was shared then, but today's window hides it.
    expect(stored(), [morning.millisecondsSinceEpoch]);
  });

  test('setting the same schedule again drops nothing', () {
    final schedule = LocationSchedule(
      weekdays: [1, 2, 3, 4, 5, 6, 7],
      startMinute: 0,
      endMinute: 24 * 60 - 1,
    );
    service.setSchedule(teen.id, schedule);
    now = tz.TZDateTime(berlin, 2026, 11, 9, 12);
    final morning = tz.TZDateTime(berlin, 2026, 11, 9, 10);
    service.setSchedule(teen.id, schedule);
    service.report(teen, fixes: [at(morning)]);
    expect(stored(), [morning.millisecondsSinceEpoch]);
  });
}
