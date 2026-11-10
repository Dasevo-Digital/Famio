import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/location/location_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// A phone that was offline sends what it measured meanwhile. Outside the
/// schedule and during a pause that stays private as well.
void main() {
  late FamioServerApp app;
  late FamilyMember parent, teen;
  late LocationService service;
  late tz.Location berlin;
  late tz.TZDateTime now;

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
    // Tuesday 10 Nov 2026, 09:00 in Berlin.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 9);
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
        id: 'party',
        data: {
          'name': 'Party bei Freunden',
          'latitude': 53.60,
          'longitude': 10.00,
          'radius': 150.0,
          'notifyMemberIds': [parent.id],
        },
        updatedAt: 0,
      ),
    ]);
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  LocationFix at(tz.TZDateTime when, {double latitude = 53.60}) => LocationFix(
    latitude: latitude,
    longitude: 10.00,
    accuracy: 15,
    at: when.toUtc(),
  );

  List<int> stored() => [
    for (final p in service.history(
      teen.id,
      from: tz.TZDateTime(berlin, 2026, 11, 9),
      to: now.toUtc().add(const Duration(minutes: 1)),
    ))
      p.at.millisecondsSinceEpoch,
  ];

  List<LocationAlert> alerts() => [
    for (final r in app.records.all(
      Collections.locationAlerts,
      visibleToMember: parent.id,
    ))
      LocationAlert.fromRecord(r),
  ];

  test('positions from outside the schedule are dropped', () {
    service.setSchedule(
      teen.id,
      LocationSchedule(
        weekdays: [1, 2, 3, 4, 5],
        startMinute: 8 * 60,
        endMinute: 16 * 60,
      ),
    );
    final inWindow = tz.TZDateTime(berlin, 2026, 11, 10, 8, 58);
    service.report(
      teen,
      fixes: [
        at(tz.TZDateTime(berlin, 2026, 11, 9, 20), latitude: 53.55),
        at(tz.TZDateTime(berlin, 2026, 11, 9, 21)),
        at(tz.TZDateTime(berlin, 2026, 11, 9, 22)),
        at(inWindow, latitude: 53.50),
      ],
    );
    expect(stored(), [inWindow.millisecondsSinceEpoch]);
    expect(alerts(), isEmpty);
  });

  test('positions from a pause are dropped', () {
    now = tz.TZDateTime(berlin, 2026, 11, 9, 20);
    service.pause(
      teen.id,
      duration: const Duration(hours: 2),
      byMember: parent.id,
    );
    now = tz.TZDateTime(berlin, 2026, 11, 10, 9);
    final after = tz.TZDateTime(berlin, 2026, 11, 9, 22, 30);
    service.report(
      teen,
      fixes: [
        at(tz.TZDateTime(berlin, 2026, 11, 9, 20, 30)),
        at(tz.TZDateTime(berlin, 2026, 11, 9, 21, 30)),
        at(after, latitude: 53.50),
      ],
    );
    expect(stored(), [after.millisecondsSinceEpoch]);
    expect(alerts(), isEmpty);
  });

  test('a pause ended early protects only its own time', () {
    now = tz.TZDateTime(berlin, 2026, 11, 9, 20);
    service.pause(teen.id, byMember: parent.id);
    now = tz.TZDateTime(berlin, 2026, 11, 9, 21);
    service.resume(teen.id);
    now = tz.TZDateTime(berlin, 2026, 11, 10, 9);
    final later = tz.TZDateTime(berlin, 2026, 11, 9, 21, 30);
    service.report(
      teen,
      fixes: [at(tz.TZDateTime(berlin, 2026, 11, 9, 20, 30)), at(later)],
    );
    expect(stored(), [later.millisecondsSinceEpoch]);
    expect(alerts().single.placeId, 'party');
  });
}
