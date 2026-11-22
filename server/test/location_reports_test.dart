import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/family/sos.dart';
import 'package:famio_server/src/location/location_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

const home = (53.5600, 9.9800);
const school = (53.5750, 9.9950);

/// Edge cases of position reports, places and trips, check-ins and the
/// low-battery notice (#577).
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
    // Tuesday 10 Nov 2026, 15:50 in Berlin.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 15, 50);
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

  LocationFix fixAt(
    tz.TZDateTime when, {
    (double, double) at = home,
    double acc = 15,
  }) => LocationFix(
    latitude: at.$1,
    longitude: at.$2,
    accuracy: acc,
    at: when.toUtc(),
  );

  void place(String id, (double, double) at, {double radius = 150}) =>
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.places,
          id: id,
          data: Place(
            id: id,
            name: id,
            latitude: at.$1,
            longitude: at.$2,
            radius: radius,
            notifyMemberIds: [parent.id],
          ).toData(),
          updatedAt: 0,
        ),
      ]);

  void trip(String placeId, tz.TZDateTime startedAt) =>
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.trips,
          id: teen.id,
          data: Trip(
            memberId: teen.id,
            placeId: placeId,
            placeName: placeId,
            eta: startedAt.add(const Duration(minutes: 30)),
            startedAt: startedAt,
          ).toData(),
          updatedAt: 0,
        ),
      ]);

  bool tripEnded() =>
      app.records.get(Collections.trips, teen.id)?.deleted ?? true;

  MemberLocation? locationOf(String id) {
    final r = app.records.get(Collections.memberLocations, id);
    return r == null || r.deleted ? null : MemberLocation.fromRecord(r);
  }

  List<String> alerts() => [
    for (final a in [
      for (final r in app.records.all(
        Collections.locationAlerts,
        visibleToMember: parent.id,
      ))
        LocationAlert.fromRecord(r),
    ]..sort((a, b) => a.at.compareTo(b.at)))
      '${a.placeId}:${a.arrived ? 'an' : 'ab'}',
  ];

  int storedPoints() =>
      app.db.select(
            'SELECT count(*) AS n FROM location_points WHERE member_id = ?',
            [teen.id],
          ).first['n']
          as int;

  test('arriving at a place inside the current one is noticed', () {
    // Home with a big radius, the Kita 200 m north inside it.
    place('home', home, radius: 300);
    const kita = (53.5618, 9.9800);
    place('kita', kita, radius: 50);
    service.report(teen, fixes: [fixAt(now)]);
    trip('kita', now);
    now = now.add(const Duration(minutes: 10));
    service.report(teen, fixes: [fixAt(now, at: kita, acc: 10)]);
    expect(locationOf(teen.id)!.placeId, 'kita');
    expect(alerts(), ['home:an', 'home:ab', 'kita:an']);
    expect(tripEnded(), isTrue);
    // GPS jitter at the edge of the Kita stays quiet …
    now = now.add(const Duration(minutes: 2));
    service.report(
      teen,
      fixes: [fixAt(now, at: (53.56185 + 0.0006, 9.9800), acc: 10)],
    );
    expect(alerts(), hasLength(3));
    // … back home counts again.
    now = now.add(const Duration(minutes: 10));
    service.report(teen, fixes: [fixAt(now, acc: 10)]);
    expect(locationOf(teen.id)!.placeId, 'home');
    expect(alerts(), ['home:an', 'home:ab', 'kita:an', 'kita:ab', 'home:an']);
  });

  test('an arrival measured before the trip began does not end it', () {
    place('home', home);
    place('school', school);
    now = tz.TZDateTime(berlin, 2026, 11, 10, 8);
    service.report(teen, fixes: [fixAt(now, at: school)]);
    // Offline since; 13:00 the teen announces "on my way home".
    now = tz.TZDateTime(berlin, 2026, 11, 10, 13);
    trip('home', now);
    // What the phone measured meanwhile arrives: briefly home at 11:00,
    // back at school at 11:30.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 13, 2);
    service.report(
      teen,
      fixes: [
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 11)),
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 11, 30), at: school),
      ],
    );
    expect(tripEnded(), isFalse);
    // Home after the start ends it.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 13, 25);
    service.report(teen, fixes: [fixAt(now)]);
    expect(tripEnded(), isTrue);
  });

  test('positions measured in the window but sent after it are kept', () {
    place('home', home);
    service.setSchedule(
      teen.id,
      LocationSchedule(
        weekdays: [1, 2, 3, 4, 5],
        startMinute: 8 * 60,
        endMinute: 16 * 60,
      ),
    );
    // Home at 15:45 (inside the window), the phone offline until 16:10.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 16, 10);
    service.report(
      teen,
      fixes: [
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 15, 45)),
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 16, 5), at: school),
      ],
    );
    expect(storedPoints(), 1, reason: '15:45, not 16:05');
    expect(alerts(), ['home:an']);
    // Shown now is nothing: the window is over.
    final l = locationOf(teen.id)!;
    expect(l.state, SharingState.scheduled);
    expect(l.hasPosition, isFalse);
    expect(l.placeId, isNull);
  });

  test('positions measured before a pause but sent during it are kept', () {
    place('home', home);
    now = tz.TZDateTime(berlin, 2026, 11, 10, 10, 30);
    service.pause(
      teen.id,
      duration: const Duration(hours: 2),
      byMember: parent.id,
    );
    // 10:05 home (measured while offline), 10:40 during the pause.
    now = tz.TZDateTime(berlin, 2026, 11, 10, 11);
    final result = service.report(
      teen,
      fixes: [
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 10, 5)),
        fixAt(tz.TZDateTime(berlin, 2026, 11, 10, 10, 40), at: school),
      ],
    );
    expect(result.paused, isTrue);
    expect(storedPoints(), 1, reason: '10:05, not 10:40');
    expect(alerts(), ['home:an']);
    expect(locationOf(teen.id)!.state, SharingState.paused);
  });

  test('of a pause with an unknown start nothing is kept', () {
    place('home', home);
    // Paused by an older server version: when is unknown.
    app.db.execute(
      'INSERT INTO location_state (member_id, paused, paused_until)'
      ' VALUES (?, 1, ?)',
      [teen.id, now.add(const Duration(hours: 1)).millisecondsSinceEpoch],
    );
    service.report(
      teen,
      fixes: [fixAt(now.subtract(const Duration(hours: 5)))],
    );
    expect(storedPoints(), 0);
  });

  test('a check-in names the nearest place it lies in', () {
    // The town (big) first, the school within it.
    place('town', (53.5700, 9.9900), radius: 2000);
    place('school', school, radius: 150);
    final sos = SosService(records: app.records, accounts: app.accounts);
    final alert = sos.checkIn(
      teen,
      note: 'Bin angekommen',
      latitude: school.$1,
      longitude: school.$2,
    );
    expect(alert.placeId, 'school');
  });

  test('low battery is told once, also over a server start', () async {
    var told = 0;
    app.push.onNotice = (ids, notice, _) {
      if (notice.tag == 'battery') told++;
    };
    for (var start = 0; start < 3; start++) {
      // A server start creates a new SosService.
      SosService(
          records: app.records,
          accounts: app.accounts,
          push: app.push,
          db: app.db,
        )
        ..batteryReported(teen, 12)
        ..batteryReported(teen, 11);
    }
    await app.push.idle;
    expect(told, 1);
    // Charged, and low again after more than six hours: told again.
    SosService(
      records: app.records,
      accounts: app.accounts,
      push: app.push,
      db: app.db,
    ).batteryReported(teen, 80);
    app.db.execute(
      "UPDATE settings SET value = json_set(value, '\$.${teen.id}.warned', ?)"
      " WHERE key = 'batteryWarnings'",
      [
        DateTime.now()
            .subtract(const Duration(hours: 7))
            .millisecondsSinceEpoch,
      ],
    );
    SosService(
      records: app.records,
      accounts: app.accounts,
      push: app.push,
      db: app.db,
    ).batteryReported(teen, 14);
    await app.push.idle;
    expect(told, 2);
  });

  group('over HTTP', () {
    late Map<String, String> tokens;
    final ip = {'shelf.io.connection_info': _Info()};

    Future<(int, Map<String, Object?>)> call(
      FamilyMember who,
      String method,
      String path, {
      Object? body,
      String? raw,
    }) async {
      final r = await app.handler(
        Request(
          method,
          Uri.parse('http://famio.test/$path'),
          headers: {
            'authorization': 'Bearer ${tokens[who.id]}',
            'content-type': 'application/json',
          },
          body: raw ?? (body == null ? null : jsonEncode(body)),
          context: ip,
        ),
      );
      final text = await r.readAsString();
      final decoded = text.isEmpty ? null : jsonDecode(text);
      return (
        r.statusCode,
        decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{},
      );
    }

    setUp(() {
      tokens = {
        for (final m in [parent, teen]) m.id: app.accounts.createSession(m.id),
      };
    });

    Future<List<Object?>> batteryNotices() async {
      await app.push.idle;
      return [
        for (final n in app.notices.after(parent.id, 0))
          if ('${n['title']}'.contains('Akku')) n['title'],
      ];
    }

    Map<String, Object?> rawFix(int battery) => {
      'lat': home.$1,
      'lon': home.$2,
      'acc': 10,
      'at': DateTime.now().millisecondsSinceEpoch,
      'battery': battery,
    };

    test('no battery notice while location is hidden', () async {
      final (s, _) = await call(
        parent,
        'PATCH',
        'api/admin/settings',
        body: {
          'hiddenModules': [ServerSettings.locationModule],
        },
      );
      expect(s, 200);
      for (final level in [40, 10]) {
        final (_, answer) = await call(
          teen,
          'POST',
          'api/location/report',
          body: {
            'fixes': [rawFix(level)],
          },
        );
        expect(answer['paused'], isTrue);
      }
      expect(await batteryNotices(), isEmpty);
    });

    test('no battery notice while paused, but after the pause', () async {
      await app.locations.setCode('1234');
      final (s, _) = await call(
        parent,
        'POST',
        'api/location/pause',
        body: {'memberId': teen.id, 'code': '1234', 'minutes': 120},
      );
      expect(s, 200);
      for (final level in [40, 9]) {
        final (_, answer) = await call(
          teen,
          'POST',
          'api/location/report',
          body: {
            'fixes': [rawFix(level)],
          },
        );
        expect(answer['paused'], isTrue);
      }
      expect(await batteryNotices(), isEmpty);
      app.locations.resume(teen.id);
      await call(
        teen,
        'POST',
        'api/location/report',
        body: {
          'fixes': [rawFix(8)],
        },
      );
      expect(await batteryNotices(), hasLength(1));
    });

    test('a pause lasts from a minute to seven days', () async {
      await app.locations.setCode('1234');
      for (final minutes in [-30, 0, 7 * 24 * 60 + 1, 9007199254740991, 1.5]) {
        final (s, body) = await call(
          parent,
          'POST',
          'api/location/pause',
          body: {'memberId': teen.id, 'code': '1234', 'minutes': minutes},
        );
        expect(s, 400, reason: '$minutes');
        expect(body['error'], 'invalid_duration');
        expect(app.locations.isPaused(teen.id), isFalse);
      }
      for (final minutes in [1, 7 * 24 * 60, null]) {
        final (s, _) = await call(
          parent,
          'POST',
          'api/location/pause',
          body: {'memberId': teen.id, 'code': '1234', 'minutes': ?minutes},
        );
        expect(s, 200, reason: '$minutes');
        expect(app.locations.isPaused(teen.id), isTrue);
        app.locations.resume(teen.id);
      }
    });

    test('numbers that are none are refused', () async {
      final at = DateTime.now().millisecondsSinceEpoch;
      for (final raw in [
        '{"fixes":[{"lat":53.56,"lon":9.98,"acc":10,"at":1e400}]}',
        '{"fixes":[{"lat":53.56,"lon":9.98,"acc":10,"at":1e300}]}',
        '{"fixes":[{"lat":53.56,"lon":9.98,"acc":10,"at":$at,"battery":1e400}]}',
      ]) {
        final (s, body) = await call(
          teen,
          'POST',
          'api/location/report',
          raw: raw,
        );
        expect(s, 400, reason: raw);
        expect(body['error'], 'invalid_fix');
      }
      for (final raw in [
        '{"note":"Alles ok","latitude":1e400,"longitude":9.98}',
        '{"note":"Alles ok","latitude":95,"longitude":9.98}',
        '{"note":"Alles ok","latitude":53.56}',
      ]) {
        final (s, body) = await call(teen, 'POST', 'api/checkin', raw: raw);
        expect(s, 400, reason: raw);
        expect(body['error'], 'invalid_position');
      }
      // An emergency is raised in any case, without the broken position.
      final (s, body) = await call(
        teen,
        'POST',
        'api/sos',
        raw: '{"latitude":1e400,"longitude":9.98,"battery":1e400}',
      );
      expect(s, 201);
      expect(body['latitude'], isNull);
    });
  });
}

class _Info implements HttpConnectionInfo {
  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;
  @override
  int get remotePort => 1;
  @override
  int get localPort => 2;
}
