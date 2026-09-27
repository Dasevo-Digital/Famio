import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Plays Google: OAuth token endpoint, calendar list and CalDAV with bearer
/// tokens. CalDAV is passed on to another Famio server (with an app
/// password), with its addresses rewritten to Google's layout.
class FakeGoogle {
  FakeGoogle(this.remote, this.remoteUser, this.remoteSecret);

  final Uri remote;
  final String remoteUser;
  final String remoteSecret;
  late HttpServer server;
  late Uri base;
  final valid = <String>{};
  var tokenCalls = 0;
  var refreshes = 0;
  static const calendarId = 'oma@example.com';

  String get _davPrefix => '/dav/calendars/$remoteUser/famio/';
  String get _googlePrefix =>
      '/caldav/v2/${Uri.encodeComponent(calendarId)}/events/';

  Future<void> start() async {
    server = await io.serve(_handle, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
  }

  Future<Response> _handle(Request request) async {
    final path = '/${request.url.path}';
    if (path == '/token') {
      tokenCalls++;
      final form = Uri.splitQueryString(await request.readAsString());
      if (form['client_id'] != 'client-1' ||
          form['client_secret'] != 'geheim') {
        return Response(401, body: jsonEncode({'error': 'invalid_client'}));
      }
      if (form['grant_type'] == 'authorization_code') {
        if (form['code'] != 'good-code' || form['code_verifier'] != 'v' * 43) {
          return Response(400, body: jsonEncode({'error': 'invalid_grant'}));
        }
      } else if (form['refresh_token'] != 'refresh-1') {
        return Response(400, body: jsonEncode({'error': 'invalid_grant'}));
      } else {
        refreshes++;
      }
      final token = 'access-$tokenCalls';
      valid.add(token);
      return Response.ok(
        jsonEncode({
          'access_token': token,
          'expires_in': 3600,
          if (form['grant_type'] == 'authorization_code')
            'refresh_token': 'refresh-1',
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    final bearer = request.headers['authorization']?.replaceFirst(
      'Bearer ',
      '',
    );
    if (bearer == null || !valid.contains(bearer)) {
      return Response(401, body: 'invalid token');
    }
    if (path == '/calendarList') {
      return Response.ok(
        jsonEncode({
          'items': [
            {
              'id': calendarId,
              'summary': 'Oma',
              'primary': true,
              'backgroundColor': '#16a765',
            },
          ],
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    final plainPrefix = _googlePrefix.replaceAll('%40', '@');
    String toDav(String text) => text
        .replaceAll(_googlePrefix, _davPrefix)
        .replaceAll(plainPrefix, _davPrefix);
    if (!path.startsWith(_googlePrefix) && !path.startsWith(plainPrefix)) {
      return Response.notFound('');
    }
    final target = remote.replace(path: toDav(path));
    final forward = http.Request(request.method, target)
      ..followRedirects = false
      ..headers.addAll({
        for (final h in ['content-type', 'depth', 'if-match', 'if-none-match'])
          if (request.headers[h] != null) h: request.headers[h]!,
        'authorization':
            'Basic ${base64.encode(utf8.encode('$remoteUser:$remoteSecret'))}',
      })
      ..body = toDav(await request.readAsString());
    final response = await http.Response.fromStream(await forward.send());
    return Response(
      response.statusCode,
      body: response.body.replaceAll(_davPrefix, _googlePrefix),
      headers: {
        for (final h in ['content-type', 'etag'])
          if (response.headers[h] != null) h: response.headers[h]!,
      },
    );
  }
}

void main() {
  late FamioServerApp remoteApp;
  late HttpServer remoteServer;
  late FakeGoogle google;
  late FamioServerApp app;
  late HttpServer server;
  late Uri base;
  late String token;

  Future<Map<String, Object?>> call(
    Uri root,
    String method,
    String path,
    String bearer, [
    Object? body,
  ]) async {
    final request = http.Request(method, root.resolve(path))
      ..headers['authorization'] = 'Bearer $bearer'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    expect(response.statusCode, lessThan(300), reason: response.body);
    return (jsonDecode(response.body) as Map).cast();
  }

  Future<String> setup(Uri root) async =>
      (jsonDecode(
                (await http.post(
                  root.resolve('api/auth/setup'),
                  headers: {'content-type': 'application/json'},
                  body: jsonEncode({
                    'username': 'oma',
                    'password': 'geheim123',
                  }),
                )).body,
              )
              as Map)['token']
          as String;

  setUp(() async {
    remoteApp = FamioServerApp.inMemory();
    remoteServer = await io.serve(
      remoteApp.handler,
      InternetAddress.loopbackIPv4,
      0,
    );
    final remoteBase = Uri.parse('http://localhost:${remoteServer.port}/');
    final remoteToken = await setup(remoteBase);
    final secret =
        (await call(remoteBase, 'POST', 'api/me/app-passwords', remoteToken, {
              'name': 'Google-Attrappe',
            }))['secret']
            as String;
    remoteApp.records.writeAs(remoteApp.accounts.members().single.id, [
      SyncRecord(
        collection: Collections.events,
        id: 'g1',
        data: CalendarEvent(
          id: 'g1',
          title: 'Termin aus Google',
          start: DateTime.now().add(const Duration(days: 2)),
          end: DateTime.now().add(const Duration(days: 2, hours: 1)),
        ).toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    google = FakeGoogle(remoteBase, 'oma', secret);
    await google.start();

    app = FamioServerApp.inMemory(googleBase: google.base);
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    token = await setup(base);
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
    await google.server.close(force: true);
    await remoteServer.close(force: true);
    await remoteApp.close();
  });

  Map<String, Object?> login({String code = 'good-code'}) => {
    'clientId': 'client-1',
    'clientSecret': 'geheim',
    'code': code,
    'codeVerifier': 'v' * 43,
    'redirectUri': 'http://127.0.0.1:5555/',
  };

  test('google login, calendar choice and two-way sync', () async {
    final connect = await call(
      base,
      'POST',
      'api/calendar/google/connect',
      token,
      login(),
    );
    expect(connect['email'], FakeGoogle.calendarId);
    final calendar = CalDavCalendarInfo.fromJson(
      ((connect['calendars'] as List).single as Map).cast(),
    );
    expect(calendar.name, 'Oma');
    expect(calendar.color, 0xFF16A765);

    final account = CalDavAccount.fromJson(
      await call(base, 'POST', 'api/calendar/caldav', token, {
        'calendarUrl': calendar.url,
        'calendarName': calendar.name,
        'googleGrant': connect['grant'],
      }),
    );
    expect(account.error, isNull);
    expect(account.google, isTrue);
    expect(account.username, FakeGoogle.calendarId);
    final titles = [
      for (final r in app.records.all(Collections.events))
        CalendarEvent.fromRecord(r).title,
    ];
    expect(titles, contains('Termin aus Google'));

    // A Famio event goes to Google.
    final now = DateTime.now().add(const Duration(days: 3));
    app.records.writeAs(app.accounts.members().single.id, [
      SyncRecord(
        collection: Collections.events,
        id: 'f1',
        data: CalendarEvent(
          id: 'f1',
          title: 'Aus Famio',
          start: now,
          end: now.add(const Duration(hours: 1)),
        ).toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    // Google revokes the access token early: Famio refreshes and retries.
    google.valid.clear();
    final synced = CalDavAccount.fromJson(
      await call(base, 'POST', 'api/calendar/caldav/${account.id}/sync', token),
    );
    expect(synced.error, isNull);
    expect(google.refreshes, greaterThanOrEqualTo(1));
    expect(remoteApp.records.get(Collections.events, 'f1'), isNotNull);

    // The grant was used once and is gone.
    final reuse = await http.post(
      base.resolve('api/calendar/caldav'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'calendarUrl': calendar.url,
        'calendarName': 'x',
        'googleGrant': connect['grant'],
      }),
    );
    expect(reuse.statusCode, 400);
  });

  test('wrong codes and clients are explained', () async {
    final response = await http.post(
      base.resolve('api/calendar/google/connect'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode(login(code: 'stale')),
    );
    expect(response.statusCode, 400);
    expect(response.body, contains('abgelaufen'));
  });
}
