import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Home and school in Hamburg, about 2 km apart.
const home = (53.5600, 9.9800);
const school = (53.5750, 9.9950);

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late String parentToken;
  late String parentId;
  late String kidToken;
  late String kidId;

  Future<http.Response> call(
    String method,
    String path,
    String token, [
    Object? body,
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    return http.Response.fromStream(await request.send());
  }

  Future<Map<String, Object?>> ok(
    String method,
    String path,
    String token, [
    Object? body,
  ]) async {
    final r = await call(method, path, token, body);
    expect(r.statusCode, lessThan(300), reason: r.body);
    return (jsonDecode(r.body) as Map).cast();
  }

  Map<String, Object?> fix((double, double) at, DateTime time, {double? acc}) =>
      LocationFix(
        latitude: at.$1,
        longitude: at.$2,
        accuracy: acc ?? 15,
        at: time,
        battery: 80,
      ).toJson();

  MemberLocation? locationOf(String id) {
    final r = app.records.get(Collections.memberLocations, id);
    return r == null || r.deleted ? null : MemberLocation.fromRecord(r);
  }

  List<LocationAlert> alertsFor(String id) => [
    for (final r in app.records.all(
      Collections.locationAlerts,
      visibleToMember: id,
    ))
      LocationAlert.fromRecord(r),
  ];

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final setup =
        jsonDecode(
              (await http.post(
                base.resolve('api/auth/setup'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'username': 'mama',
                  'password': 'geheim123',
                  'setupCode': app.setupCode,
                }),
              )).body,
            )
            as Map;
    parentToken = setup['token'] as String;
    parentId = (setup['member'] as Map)['id'] as String;
    kidId =
        (await ok('POST', 'api/members', parentToken, {
              'username': 'mia',
              'displayName': 'Mia',
              'password': 'mia-geheim',
            }))['id']
            as String;
    kidToken =
        jsonDecode(
              (await http.post(
                base.resolve('api/auth/login'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({'username': 'mia', 'password': 'mia-geheim'}),
              )).body,
            )['token']
            as String;

    // Places come from the family through normal sync.
    await ok('POST', 'api/sync', parentToken, {
      'since': 0,
      'changes': [
        for (final (id, name, at) in [
          ('home', 'Zuhause', home),
          ('school', 'Schule', school),
        ])
          SyncRecord(
            collection: Collections.places,
            id: id,
            data: Place(
              id: id,
              name: name,
              latitude: at.$1,
              longitude: at.$2,
              notifyMemberIds: [parentId],
            ).toData(),
            updatedAt: 1,
          ).toJson(),
      ],
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  test('positions update the family view and trigger place notices', () async {
    final t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
    var result = LocationReportResult.fromJson(
      await ok('POST', 'api/location/report', kidToken, {
        'fixes': [fix(home, t0)],
        'device': 'Pixel von Mia',
      }),
    );
    expect(result.paused, isFalse);
    var mia = locationOf(kidId)!;
    expect(mia.placeId, 'home');
    expect(mia.device, 'Pixel von Mia');
    expect(mia.battery, 80);
    expect(alertsFor(parentId).single.text('Mia'), contains('Zuhause'));

    // On the way (imprecise fix ignored for places), then at school.
    await ok('POST', 'api/location/report', kidToken, {
      'fixes': [
        fix((53.5680, 9.9870), t0.add(const Duration(minutes: 10))),
        fix(school, t0.add(const Duration(minutes: 20)), acc: 900),
        fix(school, t0.add(const Duration(minutes: 21))),
      ],
    });
    mia = locationOf(kidId)!;
    expect(mia.placeId, 'school');
    final texts = [
      for (final a in alertsFor(parentId)..sort((a, b) => a.at.compareTo(b.at)))
        a.text('Mia'),
    ];
    expect(texts, [
      'Mia ist bei „Zuhause“ angekommen',
      'Mia hat „Zuhause“ verlassen',
      'Mia ist bei „Schule“ angekommen',
    ]);
    // Only who asked is notified; Mia sees nothing.
    expect(alertsFor(kidId), isEmpty);
    // The parents' phone gets them with its own report.
    final parentReport = await ok('POST', 'api/location/report', parentToken, {
      'fixes': <Object>[],
      'alertsSince': 0,
    });
    expect([
      for (final a in parentReport['alerts'] as List) (a as Map)['text'],
    ], hasLength(3));

    // The same fixes sent again (lost answer) change nothing.
    final rev = app.records.currentRev;
    await ok('POST', 'api/location/report', kidToken, {
      'fixes': [fix(school, t0.add(const Duration(minutes: 21)))],
    });
    expect(app.records.currentRev, rev);
  });

  test('pausing needs the parents code; resuming does not', () async {
    // No code set yet.
    var r = await call('POST', 'api/location/pause', kidToken, {'code': '1'});
    expect(r.statusCode, 409);
    // Only admins set it.
    r = await call('PUT', 'api/admin/location-code', kidToken, {
      'code': '4711',
    });
    expect(r.statusCode, 403);
    await ok('PUT', 'api/admin/location-code', parentToken, {'code': '4711'});
    final overview = ServerOverview.fromJson(
      await ok('GET', 'api/admin/overview', parentToken),
    );
    expect(overview.locationCodeSet, isTrue);

    r = await call('POST', 'api/location/pause', kidToken, {'code': '1234'});
    expect(r.statusCode, 403);
    await ok('POST', 'api/location/pause', kidToken, {
      'code': '4711',
      'minutes': 60,
    });
    var mia = locationOf(kidId)!;
    expect(mia.state, SharingState.paused);
    expect(mia.pausedUntil, isNotNull);

    // While paused, positions are not stored and the phone is told so.
    final result = LocationReportResult.fromJson(
      await ok('POST', 'api/location/report', kidToken, {
        'fixes': [fix(school, DateTime.now().toUtc())],
      }),
    );
    expect(result.paused, isTrue);
    final history = await ok(
      'GET',
      'api/location/history?member=$kidId',
      parentToken,
    );
    expect(history['points'], isEmpty);

    // Somebody else may not resume Mia, parents may.
    r = await call('POST', 'api/location/resume', kidToken, {
      'memberId': parentId,
    });
    expect(r.statusCode, 403);
    await ok('POST', 'api/location/resume', parentToken, {'memberId': kidId});
    expect(locationOf(kidId)!.state, SharingState.active);
  });

  test(
    'a sharing schedule hides and discards locations outside its window',
    () async {
      await ok('PUT', 'api/admin/location-code', parentToken, {'code': '4711'});
      final now = DateTime.now().toUtc();
      await ok('POST', 'api/location/report', kidToken, {
        'fixes': [fix(home, now)],
      });
      expect(locationOf(kidId)!.hasPosition, isTrue);

      final forbidden = await call(
        'GET',
        'api/location/schedule?member=$parentId',
        kidToken,
      );
      expect(forbidden.statusCode, 403);

      // Select a day that is not today in the server's configured time zone.
      // This also makes the test safe on Sundays and around UTC midnight.
      final localNow = tz.TZDateTime.now(app.location);
      final inactiveDay = localNow.weekday == DateTime.sunday
          ? DateTime.monday
          : DateTime.sunday;
      final changed = await ok('PUT', 'api/location/schedule', parentToken, {
        'code': '4711',
        'memberId': kidId,
        'schedule': {
          'weekdays': [inactiveDay],
          'startMinute': 0,
          'endMinute': 1439,
        },
      });
      expect((changed['schedule'] as Map)['weekdays'], [inactiveDay]);
      final hidden = locationOf(kidId)!;
      expect(hidden.state, SharingState.scheduled);
      expect(hidden.hasPosition, isFalse);

      final response = LocationReportResult.fromJson(
        await ok('POST', 'api/location/report', kidToken, {
          'fixes': [fix(school, now.add(const Duration(minutes: 1)))],
        }),
      );
      expect(
        response.paused,
        isFalse,
        reason: 'phone keeps its low-power heartbeat',
      );
      expect(locationOf(kidId)!.state, SharingState.scheduled);
      final history = await ok(
        'GET',
        'api/location/history?member=$kidId',
        parentToken,
      );
      expect(
        history['points'],
        hasLength(1),
        reason: 'the hidden report was not stored',
      );

      await ok('PUT', 'api/location/schedule', parentToken, {
        'code': '4711',
        'memberId': kidId,
        'schedule': null,
      });
      expect(locationOf(kidId)!.state, SharingState.active);
    },
  );

  test('wrong codes are throttled', () async {
    await ok('PUT', 'api/admin/location-code', parentToken, {'code': '4711'});
    var last = 0;
    for (var i = 0; i < 12; i++) {
      last = (await call('POST', 'api/location/pause', kidToken, {
        'code': '000$i',
      })).statusCode;
    }
    expect(last, 429);
  });

  test('the device token can only report positions', () async {
    final device =
        (await ok('POST', 'api/location/device-token', kidToken, {
              'device': 'Pixel',
            }))['token']
            as String;
    await ok('POST', 'api/location/report', device, {
      'fixes': [fix(home, DateTime.now().toUtc())],
    });
    expect(locationOf(kidId)!.placeId, 'home');
    for (final (method, path) in [
      ('POST', 'api/sync'),
      ('GET', 'api/me'),
      ('GET', 'api/members'),
      ('GET', 'api/location/history'),
    ]) {
      final r = await call(method, path, device, {'since': 0});
      expect(r.statusCode, 401, reason: path);
    }
    // It shows up among the devices and can be signed out.
    final users = await ok('GET', 'api/admin/users', parentToken);
    expect(jsonEncode(users), contains('Pixel · Standort'));
  });

  test('history is for parents and the member only, and expires', () async {
    final now = DateTime.now().toUtc();
    await ok('POST', 'api/location/report', parentToken, {
      'fixes': [
        fix(home, now.subtract(const Duration(days: 8))), // too old
        fix(home, now.subtract(const Duration(hours: 2))),
        fix(school, now.subtract(const Duration(hours: 1))),
      ],
    });
    final mine = await ok('GET', 'api/location/history', parentToken);
    expect(mine['points'], hasLength(2));
    final r = await call(
      'GET',
      'api/location/history?member=$parentId',
      kidToken,
    );
    expect(r.statusCode, 403);

    // A week later everything is gone.
    app.locations.collectGarbage(
      now: DateTime.now().add(const Duration(days: 7)),
    );
    final later = await ok('GET', 'api/location/history', parentToken);
    expect(later['points'], isEmpty);
    expect(alertsFor(parentId), isEmpty);
  });

  test('the administrator-selected retention governs history cleanup', () async {
    app.settings.update({'locationHistoryDays': 30});
    final now = DateTime.now().toUtc();
    await ok('POST', 'api/location/report', parentToken, {
      'fixes': [fix(home, now.subtract(const Duration(days: 20)))],
    });
    expect(
      (await ok(
        'GET',
        'api/location/history?from=${now.subtract(const Duration(days: 30)).toIso8601String()}',
        parentToken,
      ))['points'],
      hasLength(1),
    );
    app.settings.update({'locationHistoryDays': 1});
    app.locations.collectGarbage(now: now);
    expect(
      (await ok('GET', 'api/location/history', parentToken))['points'],
      isEmpty,
    );
  });

  test('clients cannot write positions or notices themselves', () async {
    final response = SyncResponse.fromJson(
      await ok('POST', 'api/sync', kidToken, {
        'since': 0,
        'changes': [
          SyncRecord(
            collection: Collections.memberLocations,
            id: parentId,
            data: const {'latitude': 1, 'longitude': 1},
            updatedAt: 1,
          ).toJson(),
        ],
      }),
    );
    expect(response.rejected, isEmpty);
    expect(locationOf(parentId), isNull);
  });

  test('deleting a member removes their location', () async {
    await ok('POST', 'api/location/report', kidToken, {
      'fixes': [fix(home, DateTime.now().toUtc())],
    });
    await ok('POST', 'api/location/report', kidToken, {
      'fixes': [
        fix(school, DateTime.now().toUtc().add(const Duration(minutes: 1))),
      ],
    });
    expect(alertsFor(parentId), isNotEmpty);
    await ok('DELETE', 'api/members/$kidId', parentToken);
    expect(locationOf(kidId), isNull);
    // Notices about Mia are gone as well.
    expect(alertsFor(parentId), isEmpty);
  });
}
