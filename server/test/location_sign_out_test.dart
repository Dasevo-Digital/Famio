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

/// However a phone's location token is signed out – on the phone, in
/// "Meine Geräte", by an admin – sharing ends there and nothing it measured
/// stays visible (#594). Signing out needs the parents' code only where
/// one is set (#595); a pause that ends without a phone leaves nothing
/// behind (#587).
void main() {
  late FamioServerApp app;
  late FamilyMember parent, teen;
  late List<String> audit;

  setUp(() async {
    audit = [];
    app = FamioServerApp.inMemory(auditLog: audit.add);
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
    await app.accounts.setPassword(teen.id, 'alt-Kennwort-17', check: false);
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

  List<String> sharingEnded() => [
    for (final line in audit)
      if (line.contains('Teilen des Standorts')) line,
  ];

  group('over HTTP', () {
    final ip = {'shelf.io.connection_info': _Info()};

    /// [body] null sends none, like older apps on DELETE.
    Future<(int, Map<String, Object?>)> call(
      String method,
      String token,
      String path, [
      Object? body,
    ]) async {
      final r = await app.handler(
        Request(
          method,
          Uri.parse('http://famio.test/$path'),
          headers: {
            'authorization': 'Bearer $token',
            if (body != null) 'content-type': 'application/json',
          },
          body: body == null ? null : jsonEncode(body),
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

    late String teenApp;
    late String adminApp;

    setUp(() {
      teenApp = app.accounts.createSession(teen.id, device: 'Laptop');
      adminApp = app.accounts.createSession(parent.id, device: 'Mac');
    });

    Future<String> deviceToken(String device) async {
      final session = app.accounts.createSession(teen.id, device: device);
      final (status, body) = await call(
        'POST',
        session,
        'api/location/device-token',
        {'device': device},
      );
      expect(status, 201);
      // The phone keeps only its location token.
      app.accounts.deleteSession(session);
      return body['token'] as String;
    }

    var second = 0;
    Future<int> report(
      String token,
      (double, double) at, {
      String device = 'Pixel',
    }) async {
      final (status, _) = await call('POST', token, 'api/location/report', {
        'fixes': [
          LocationFix(
            latitude: at.$1,
            longitude: at.$2,
            accuracy: 10,
            // Each later than the one before.
            at: DateTime.now().toUtc().add(Duration(seconds: ++second)),
          ).toJson(),
        ],
        'device': device,
      });
      return status;
    }

    /// The id of the teen's session of the phone [device] in "Meine Geräte".
    Future<String> locationSession(String device) async {
      final (status, body) = await call('GET', teenApp, 'api/me/sessions');
      expect(status, 200);
      final sessions = [
        for (final s in body['sessions'] as List)
          DeviceSession.fromJson((s as Map).cast()),
      ];
      // Only the location tokens are marked.
      expect(
        sessions.where((s) => s.location).map((s) => s.device),
        everyElement(endsWith(' · Standort')),
      );
      expect(sessions.singleWhere((s) => s.device == 'Laptop').location, false);
      return sessions
          .singleWhere((s) => s.location && s.device!.startsWith(device))
          .id;
    }

    test('a password change keeps the phone sharing', () async {
      final phone = await deviceToken('Pixel');
      expect(await report(phone, home), 200);
      final other = app.accounts.createSession(teen.id, device: 'Tablet');
      final (status, body) = await call('PUT', teenApp, 'api/me/password', {
        'currentPassword': 'alt-Kennwort-17',
        'newPassword': 'Fahrrad-Wolke-93',
      });
      expect(status, 200);
      expect(body['signedOut'], 1, reason: 'the tablet only');
      expect(app.accounts.userForToken(other), isNull);
      // The location token goes on reporting; nothing was taken away.
      expect(await report(phone, school), 200);
      expect(locationOf(teen.id)?.hasPosition, isTrue);
      expect(sharingEnded(), isEmpty);
    });

    test('"Meine Geräte" ends sharing on a phone with the parents code, '
        'the other phone counts at once', () async {
      await app.locations.setCode('4711');
      final tablet = await deviceToken('Tablet');
      expect(await report(tablet, home, device: 'Tablet'), 200);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final phone = await deviceToken('Pixel');
      expect(await report(phone, school), 200);
      expect(locationOf(teen.id)?.device, 'Pixel');
      final sid = await locationSession('Pixel');

      // An older app sends no body: the code is missing.
      var (status, body) = await call(
        'DELETE',
        teenApp,
        'api/me/sessions/$sid',
      );
      expect(status, 403);
      expect(body['error'], 'wrong_code');
      (status, body) = await call('DELETE', teenApp, 'api/me/sessions/$sid', {
        'code': '1234',
      });
      expect(status, 403);
      expect(body['error'], 'wrong_code');
      expect(await report(phone, school), 200, reason: 'still signed in');

      (status, _) = await call('DELETE', teenApp, 'api/me/sessions/$sid', {
        'code': '4711',
      });
      expect(status, 200);
      expect(await report(phone, school), 401);
      // Nothing the phone measured stays.
      var l = locationOf(teen.id)!;
      expect(l.hasPosition, isFalse);
      expect(l.placeId, isNull);
      expect(l.device, isNull);
      expect(l.otherDevice, isNull);
      expect(sharingEnded(), [
        '[audit] @teen hat das Teilen des Standorts auf Pixel beendet',
      ]);
      // The tablet counts at once, not only after two days.
      final told = alerts();
      expect(await report(tablet, home, device: 'Tablet'), 200);
      l = locationOf(teen.id)!;
      expect(l.device, 'Tablet');
      expect(l.placeId, 'home');
      expect(l.hasPosition, isTrue);
      // Nobody moved: no departure from school, no arrival at home.
      expect(alerts(), told);
    });

    test('without a parents code, or with location hidden, a phone can be '
        'signed out in "Meine Geräte"', () async {
      final phone = await deviceToken('Pixel');
      expect(await report(phone, home), 200);
      var (status, _) = await call(
        'DELETE',
        teenApp,
        'api/me/sessions/${await locationSession('Pixel')}',
      );
      expect(status, 200);
      expect(locationOf(teen.id), isNull);

      await app.locations.setCode('4711');
      await call('PATCH', adminApp, 'api/admin/settings', {
        'hiddenModules': [ServerSettings.locationModule],
      });
      final again = await deviceToken('Pixel');
      expect(await report(again, home), 200);
      (status, _) = await call(
        'DELETE',
        teenApp,
        'api/me/sessions/${await locationSession('Pixel')}',
      );
      expect(status, 200);
      expect(await report(again, home), 401);
    });

    test(
      'a phone can always be signed out without a parents code (#595)',
      () async {
        final phone = await deviceToken('Pixel');
        expect(await report(phone, home), 200);
        var (status, body) = await call('POST', teenApp, 'api/location/code', {
          'code': '',
        });
        expect(status, 200);
        expect(body, {'ok': true, 'noCode': true});
        // Nobody is paused by it.
        expect(locationOf(teen.id)?.state, SharingState.active);

        await app.locations.setCode('4711');
        (status, body) = await call('POST', teenApp, 'api/location/code', {
          'code': '',
        });
        expect(status, 403);
        expect(body['error'], 'wrong_code');
        (status, body) = await call('POST', teenApp, 'api/location/code', {
          'code': '4711',
        });
        expect(status, 200);
        expect(body['noCode'], isNull);

        // Location hidden: nothing to protect.
        await call('PATCH', adminApp, 'api/admin/settings', {
          'hiddenModules': [ServerSettings.locationModule],
        });
        (status, body) = await call('POST', teenApp, 'api/location/code', {
          'code': '',
        });
        expect(status, 200);
        expect(body, {'ok': true, 'noCode': true});
        // A pause still needs a code.
        await app.locations.setCode(null);
        (status, body) = await call('POST', teenApp, 'api/location/pause', {
          'code': '',
        });
        expect(status, 409);
      },
    );

    test('asking without a code is no wrong guess (#595)', () async {
      await app.locations.setCode('4711');
      final phone = await deviceToken('Pixel');
      expect(await report(phone, home), 200);
      final sid = await locationSession('Pixel');
      // Apps ask with an empty or missing code whether one is needed; more
      // often than wrong guesses may be made.
      for (var i = 0; i < 10; i++) {
        for (final (method, path, body) in [
          ('POST', 'api/location/code', {'code': ''}),
          ('POST', 'api/location/code', <String, Object?>{}),
          ('DELETE', 'api/me/sessions/$sid', null),
          ('DELETE', 'api/me/sessions/$sid', {'code': ''}),
        ]) {
          final (status, answer) = await call(method, teenApp, path, body);
          expect(status, 403, reason: '$method $path $body');
          expect(answer['error'], 'wrong_code');
        }
      }
      final (status, _) = await call(
        'DELETE',
        teenApp,
        'api/me/sessions/$sid',
        {'code': '4711'},
      );
      expect(status, 200);
      expect(await report(phone, home), 401);
    });

    test('an admin signing a member out everywhere ends sharing on the '
        'phone', () async {
      await app.locations.setCode('4711');
      final phone = await deviceToken('Pixel');
      expect(await report(phone, home), 200);
      final (status, body) = await call(
        'DELETE',
        adminApp,
        'api/admin/users/${teen.id}/sessions',
      );
      expect(status, 200, reason: 'parents need no code');
      expect(body['signedOut'], 2);
      expect(await report(phone, home), 401);
      expect(locationOf(teen.id), isNull);
      // Nobody is told two days later that the phone is silent.
      expect(
        app.locations.newlySilent(
          now: DateTime.now().add(const Duration(days: 3)),
        ),
        isEmpty,
      );
      expect(sharingEnded(), [
        '[audit] @mama hat das Teilen des Standorts von @teen auf Pixel '
            'beendet',
      ]);
    });

    test('a password reset by an admin ends sharing on the phone', () async {
      final phone = await deviceToken('Pixel');
      expect(await report(phone, home), 200);
      final (status, _) = await call(
        'PUT',
        adminApp,
        'api/admin/users/${teen.id}/password',
        {'password': 'Neues-Kennwort-58'},
      );
      expect(status, 200);
      expect(await report(phone, home), 401);
      expect(locationOf(teen.id), isNull);
      expect(sharingEnded(), hasLength(1));
    });

    test('signing out on the phone is noted once', () async {
      final phone = await deviceToken('Pixel');
      expect(await report(phone, home), 200);
      final (status, _) = await call('POST', phone, 'api/auth/logout', {});
      expect(status, 200);
      expect(locationOf(teen.id), isNull);
      expect(sharingEnded(), [
        '[audit] @teen hat das Teilen des Standorts auf Pixel beendet',
      ]);
    });
  });

  group('in the service', () {
    late LocationService service;
    late tz.TZDateTime now;

    setUp(() {
      now = tz.TZDateTime(tz.getLocation('Europe/Berlin'), 2026, 11, 10, 15);
      service = LocationService(
        db: app.db,
        records: app.records,
        accounts: app.accounts,
        onChanged: () {},
        clock: () => now,
      );
    });

    LocationFix fixAt((double, double) at) => LocationFix(
      latitude: at.$1,
      longitude: at.$2,
      accuracy: 15,
      at: now.toUtc(),
    );

    void ipad((double, double) at) => service.report(
      teen,
      fixes: [fixAt(at)],
      device: 'iPad',
      deviceKey: 's:ipad',
      enabledAt: DateTime.utc(2026, 9, 1),
    );
    void iphone((double, double) at) => service.report(
      teen,
      fixes: [fixAt(at)],
      device: 'iPhone',
      deviceKey: 's:iphone',
      enabledAt: DateTime.utc(2026, 11, 1),
    );

    test('after the phone that counted signs out, the other one tells the '
        'place without notices; real moves are told again', () {
      ipad(home);
      now = now.add(const Duration(minutes: 1));
      iphone(school);
      expect(alerts(), ['home:an', 'home:ab', 'school:an']);
      // The iPhone (at school) signs out; the iPad lies at home.
      now = now.add(const Duration(minutes: 1));
      service.deviceSignedOut(teen.id, 's:iphone');
      now = now.add(const Duration(minutes: 1));
      ipad(home);
      expect(locationOf(teen.id)!.placeId, 'home');
      expect(alerts(), ['home:an', 'home:ab', 'school:an']);
      // Now Teen takes the iPad to school.
      now = now.add(const Duration(minutes: 20));
      ipad(school);
      expect(alerts(), [
        'home:an',
        'home:ab',
        'school:an',
        'home:ab',
        'school:an',
      ]);
      expect(locationOf(teen.id)!.placeId, 'school');
    });

    test('a coarse position tells nothing; the next precise one does', () {
      iphone(school);
      service.deviceSignedOut(teen.id, 's:iphone');
      now = now.add(const Duration(minutes: 1));
      service.report(
        teen,
        fixes: [
          LocationFix(
            latitude: home.$1,
            longitude: home.$2,
            accuracy: 900,
            at: now.toUtc(),
          ),
        ],
        device: 'iPad',
        deviceKey: 's:ipad',
      );
      expect(locationOf(teen.id)!.placeId, isNull);
      now = now.add(const Duration(minutes: 2));
      ipad(home);
      expect(locationOf(teen.id)!.placeId, 'home');
      expect(alerts(), ['school:an']);
    });

    test('a phone switched on after the last one signed out is no '
        'arrival either', () {
      iphone(school);
      service.deviceSignedOut(teen.id, 's:iphone');
      expect(locationOf(teen.id), isNull);
      now = now.add(const Duration(hours: 5));
      ipad(home);
      expect(locationOf(teen.id)!.placeId, 'home');
      expect(alerts(), ['school:an']);
    });

    test('the phone that counts now gives the last contact, so its '
        'silence is told', () {
      ipad(home);
      final ipadReported = now.millisecondsSinceEpoch;
      now = now.add(const Duration(minutes: 1));
      iphone(school);
      now = now.add(const Duration(minutes: 1));
      service.deviceSignedOut(teen.id, 's:iphone');
      final l = locationOf(teen.id)!;
      expect(l.state, SharingState.active);
      expect(l.hasPosition, isFalse);
      expect(l.lastContact?.millisecondsSinceEpoch, ipadReported);
      // The iPad stays in a drawer.
      final silent = service.newlySilent(
        now: now.add(const Duration(hours: 49)),
      );
      expect([for (final (m, _) in silent) m.id], [teen.id]);
    });

    test('a pause that ends without a phone leaves nothing behind', () {
      iphone(home);
      service.pause(
        teen.id,
        duration: const Duration(hours: 1),
        byMember: parent.id,
      );
      service.deviceSignedOut(teen.id, 's:iphone');
      expect(locationOf(teen.id)!.state, SharingState.paused);
      now = now.add(const Duration(hours: 2));
      expect(service.followClock(), isTrue);
      expect(locationOf(teen.id), isNull);
      expect(service.newlySilent(now: now.add(const Duration(days: 3))), []);
    });

    test('a pause that ends with another phone shares its last contact', () {
      ipad(home);
      final ipadReported = now.millisecondsSinceEpoch;
      now = now.add(const Duration(minutes: 1));
      iphone(school);
      service.pause(
        teen.id,
        duration: const Duration(hours: 1),
        byMember: parent.id,
      );
      service.deviceSignedOut(teen.id, 's:iphone');
      now = now.add(const Duration(hours: 2));
      service.followClock();
      final l = locationOf(teen.id)!;
      expect(l.state, SharingState.active);
      expect(l.lastContact?.millisecondsSinceEpoch, ipadReported);
      expect(
        [
          for (final (m, _) in service.newlySilent(
            now: now.add(const Duration(hours: 47)),
          ))
            m.id,
        ],
        [teen.id],
      );
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
