import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/location/location_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

const home = (53.5600, 9.9800);
const school = (53.5750, 9.9950);

/// One member, several devices sharing (an old phone at home, the new one
/// along): only the one switched on last counts (#576). Signing out on a
/// phone ends sharing there (#577).
void main() {
  late FamioServerApp app;
  late FamilyMember parent, teen;
  late LocationService service;
  late tz.Location berlin;
  late tz.TZDateTime now;
  late List<int> batteries;

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
    batteries = [];
    service = LocationService(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      onChanged: () {},
      clock: () => now,
    )..onBattery = (_, level) => batteries.add(level);
    for (final (id, at) in [('home', home), ('school', school)]) {
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.places,
          id: id,
          data: Place(
            id: id,
            name: id,
            latitude: at.$1,
            longitude: at.$2,
            notifyMemberIds: [parent.id],
          ).toData(),
          updatedAt: 0,
        ),
      ]);
    }
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  LocationFix fixAt((double, double) at, {int? battery}) => LocationFix(
    latitude: at.$1,
    longitude: at.$2,
    accuracy: 15,
    at: now.toUtc(),
    battery: battery,
  );

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

  final ipadOn = DateTime.utc(2026, 9, 1);
  final iphoneOn = DateTime.utc(2026, 11, 1);

  void ipad({(double, double) at = home, int? battery}) => service.report(
    teen,
    fixes: [fixAt(at, battery: battery)],
    device: 'iPad',
    deviceKey: 's:ipad',
    enabledAt: ipadOn,
  );
  void iphone({(double, double) at = school, int? battery}) => service.report(
    teen,
    fixes: [fixAt(at, battery: battery)],
    device: 'iPhone',
    deviceKey: 's:iphone',
    enabledAt: iphoneOn,
  );

  test('only the device switched on last counts', () {
    // The iPad at home, the iPhone along at school, both report every two
    // minutes.
    for (var i = 0; i < 12; i++) {
      now = now.add(const Duration(minutes: 1));
      i.isEven ? ipad() : iphone();
    }
    // One switch when the iPhone appears, then quiet.
    expect(alerts(), ['home:an', 'home:ab', 'school:an']);
    final l = locationOf(teen.id)!;
    expect(l.device, 'iPhone');
    expect(l.placeId, 'school');
    expect((l.latitude, l.longitude), school);
    expect(l.otherDevice, 'iPad');
    // Nothing of the iPad is kept once the iPhone counts.
    final kept = service.history(
      teen.id,
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(minutes: 1)),
    );
    expect(kept, hasLength(7), reason: 'the first iPad fix, six iPhone ones');
  });

  test('the order of the reports does not matter', () {
    // The iPhone was switched on later, even if the iPad reports first
    // after a server start.
    now = now.add(const Duration(minutes: 1));
    iphone();
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(minutes: 1));
      i.isEven ? ipad() : iphone();
    }
    expect(alerts(), ['school:an']);
    expect(locationOf(teen.id)!.device, 'iPhone');
  });

  test('only the battery of the device that counts is told', () {
    iphone(battery: 60);
    now = now.add(const Duration(minutes: 1));
    ipad(battery: 9);
    now = now.add(const Duration(minutes: 1));
    iphone(battery: 58);
    expect(batteries, [60, 58]);
  });

  test('a device silent for two days gives way, the other is named', () {
    iphone();
    now = now.add(const Duration(minutes: 2));
    ipad();
    expect(locationOf(teen.id)!.placeId, 'school');
    // The iPhone stops (left in the locker); the iPad goes on reporting.
    now = now.add(const Duration(hours: 47));
    ipad();
    expect(locationOf(teen.id)!.device, 'iPhone');
    now = now.add(const Duration(hours: 1, minutes: 1));
    ipad();
    final l = locationOf(teen.id)!;
    expect(l.device, 'iPad');
    expect(l.placeId, 'home');
    expect(l.otherDevice, isNull, reason: 'the iPhone has been silent');
    // The iPhone comes back: switched on last, it counts again.
    now = now.add(const Duration(minutes: 2));
    iphone();
    expect(locationOf(teen.id)!.device, 'iPhone');
    expect(locationOf(teen.id)!.otherDevice, 'iPad');
  });

  test('a second device that stopped is no longer named', () {
    iphone();
    now = now.add(const Duration(minutes: 1));
    ipad();
    expect(locationOf(teen.id)!.otherDevice, 'iPad');
    now = now.add(const Duration(minutes: 59));
    expect(service.followClock(), isFalse);
    now = now.add(const Duration(minutes: 2));
    expect(service.followClock(), isTrue);
    expect(locationOf(teen.id)!.otherDevice, isNull);
    expect(locationOf(teen.id)!.device, 'iPhone');
  });

  test('sharing switched on again on the same phone is one device', () {
    iphone();
    // A new token for the same phone (sharing switched off and on).
    now = now.add(const Duration(minutes: 2));
    service.report(
      teen,
      fixes: [fixAt(school)],
      device: 'iPhone',
      deviceKey: 's:iphone-again',
      enabledAt: DateTime.utc(2026, 11, 10, 15),
    );
    expect(locationOf(teen.id)!.otherDevice, isNull);
  });

  group('over HTTP', () {
    final ip = {'shelf.io.connection_info': _Info()};

    Future<(int, Map<String, Object?>)> call(
      String token,
      String path, [
      Object? body,
    ]) async {
      final r = await app.handler(
        Request(
          'POST',
          Uri.parse('http://famio.test/$path'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode(body ?? const {}),
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

    Future<String> deviceToken(String device) async {
      final session = app.accounts.createSession(teen.id, device: device);
      final (status, body) = await call(session, 'api/location/device-token', {
        'device': device,
      });
      expect(status, 201);
      return body['token'] as String;
    }

    Future<void> report(
      String token,
      (double, double) at, {
      String device = 'Pixel',
    }) async {
      final (status, _) = await call(token, 'api/location/report', {
        'fixes': [
          LocationFix(
            latitude: at.$1,
            longitude: at.$2,
            accuracy: 10,
            at: DateTime.now().toUtc(),
          ).toJson(),
        ],
        'device': device,
      });
      expect(status, 200);
    }

    test('signing out on the phone ends sharing there', () async {
      final token = await deviceToken('Pixel');
      await report(token, home);
      expect(locationOf(teen.id)?.hasPosition, isTrue);
      // Signing out of Famio on the phone signs its location token out.
      final (status, _) = await call(token, 'api/auth/logout');
      expect(status, 200);
      expect(locationOf(teen.id), isNull);
      // Nobody is told two days later that the phone is silent.
      expect(
        app.locations.newlySilent(
          now: DateTime.now().add(const Duration(days: 3)),
        ),
        isEmpty,
      );
    });

    test('a pause stays when sharing ends on the phone', () async {
      final token = await deviceToken('Pixel');
      await report(token, home);
      app.locations.pause(
        teen.id,
        duration: const Duration(hours: 1),
        byMember: parent.id,
      );
      final until = locationOf(teen.id)!.pausedUntil;
      expect(until, isNotNull);
      await call(token, 'api/auth/logout');
      final l = locationOf(teen.id)!;
      expect(l.state, SharingState.paused);
      expect(l.pausedUntil, until);
      // Nothing of what this phone measured stays visible (#587).
      expect(l.hasPosition, isFalse);
      expect(l.placeId, isNull);
      expect(l.device, isNull);
      expect(l.battery, isNull);
      // Resumed, no phone shares any more: nothing stays, also no entry
      // without a position that would never fall silent (#587).
      app.locations.resume(teen.id);
      expect(locationOf(teen.id), isNull);
    });

    test('another phone of the member goes on sharing', () async {
      final tablet = await deviceToken('Tablet');
      await report(tablet, home, device: 'Tablet');
      // Switched on later.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final phone = await deviceToken('Pixel');
      await report(phone, school);
      expect(locationOf(teen.id)?.device, 'Pixel');
      expect(locationOf(teen.id)?.otherDevice, 'Tablet');
      await call(phone, 'api/auth/logout');
      final l = locationOf(teen.id)!;
      expect(l.state, SharingState.active);
      expect(l.otherDevice, isNull);
      // Where the signed-out phone was is not shown as the member's (#587).
      expect(l.hasPosition, isFalse);
      expect(l.device, isNull);
      // The tablet counts now.
      await report(tablet, home, device: 'Tablet');
      expect(locationOf(teen.id)!.placeId, 'home');
    });

    test(
      'signing out a phone that does not count keeps the position',
      () async {
        final phone = await deviceToken('Pixel');
        await report(phone, school);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final tablet = await deviceToken('Tablet');
        await report(tablet, home, device: 'Tablet');
        expect(locationOf(teen.id)?.device, 'Tablet');
        await call(phone, 'api/auth/logout');
        final l = locationOf(teen.id)!;
        expect(l.device, 'Tablet');
        expect(l.placeId, 'home');
        expect(l.hasPosition, isTrue);
      },
    );

    test('signing out the app session leaves sharing alone', () async {
      final token = await deviceToken('Pixel');
      await report(token, home);
      final app2 = app.accounts.createSession(teen.id, device: 'Laptop');
      await call(app2, 'api/auth/logout');
      expect(locationOf(teen.id)?.hasPosition, isTrue);
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
