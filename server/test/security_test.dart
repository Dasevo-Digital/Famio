import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  Future<http.Response> send(
    String method,
    String path, {
    Object? body,
    String? token,
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..headers.addAll(headers);
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body is List<int>) {
      request.bodyBytes = body;
    } else if (body != null) {
      request.headers['content-type'] ??= 'application/json';
      request.body = jsonEncode(body);
    }
    return http.Response.fromStream(await request.send());
  }

  Map<String, Object?> json(http.Response r) =>
      (jsonDecode(r.body) as Map).cast();

  /// Admin "mama" plus members "papa" and "kind"; returns tokens and ids.
  Future<Map<String, (String token, String id)>> family() async {
    final setup = json(
      await send(
        'POST',
        'api/auth/setup',
        body: {
          'username': 'mama',
          'password': 'geheim123',
          'setupCode': app.setupCode,
        },
      ),
    );
    final result = {
      'mama': (
        setup['token'] as String,
        (setup['member'] as Map)['id'] as String,
      ),
    };
    for (final name in ['papa', 'kind']) {
      await send(
        'POST',
        'api/members',
        token: result['mama']!.$1,
        body: {'username': name, 'password': 'geheim123'},
      );
      final login = json(
        await send(
          'POST',
          'api/auth/login',
          body: {'username': name, 'password': 'geheim123'},
        ),
      );
      result[name] = (
        login['token'] as String,
        (login['member'] as Map)['id'] as String,
      );
    }
    return result;
  }

  Future<SyncResponse> sync(
    String token, {
    List<SyncRecord> changes = const [],
    int since = 0,
  }) async => SyncResponse.fromJson(
    json(
      await send(
        'POST',
        'api/sync',
        token: token,
        body: SyncRequest(since: since, changes: changes).toJson(),
      ),
    ),
  );

  var clock = DateTime.now().millisecondsSinceEpoch;
  SyncRecord doc(
    String id,
    Map<String, Object?> data, {
    bool deleted = false,
  }) => SyncRecord(
    collection: Collections.tasks,
    id: id,
    data: data,
    updatedAt: clock += 10,
    deleted: deleted,
  );

  group('record visibility', () {
    test('restricted records reach only their audience', () async {
      final f = await family();
      final (mama, mamaId) = f['mama']!;
      final (papa, papaId) = f['papa']!;
      final (kind, _) = f['kind']!;

      await sync(
        mama,
        changes: [
          doc('geschenk', {
            'title': 'Geschenk für Kind',
            'visibleTo': [mamaId, papaId],
          }),
          doc('alle', {'title': 'Für alle'}),
        ],
      );

      Set<String> titles(SyncResponse r) => {
        for (final c in r.changes)
          if (!c.deleted) c.data['title'] as String,
      };
      expect(titles(await sync(papa)), {'Geschenk für Kind', 'Für alle'});
      expect(titles(await sync(kind)), {'Für alle'});
    });

    test(
      'child logs and contacts are accepted; logs stay with guardians',
      () async {
        final f = await family();
        final (mama, mamaId) = f['mama']!;
        final (papa, papaId) = f['papa']!;
        final (kind, _) = f['kind']!;
        final response = await sync(
          mama,
          changes: [
            SyncRecord(
              collection: Collections.childLogs,
              id: 'fever',
              data: {
                'childId': 'c1',
                'kind': 'temperature',
                'temperatureC': 38.9,
                'visibleTo': [mamaId, papaId],
              },
              updatedAt: clock += 10,
            ),
            SyncRecord(
              collection: Collections.contacts,
              id: 'doc',
              data: {'name': 'Dr. Sommer', 'role': 'pediatrician'},
              updatedAt: clock += 10,
            ),
          ],
        );
        expect(response.rejected, isEmpty);
        Set<String> ids(SyncResponse r) => {
          for (final c in r.changes)
            if (!c.deleted) '${c.collection}/${c.id}',
        };
        expect(
          ids(await sync(papa)),
          containsAll(['child_logs/fever', 'contacts/doc']),
        );
        expect(ids(await sync(kind)), {'contacts/doc'});
      },
    );

    test('authors are always part of the audience', () async {
      final f = await family();
      final (mama, mamaId) = f['mama']!;
      final (_, papaId) = f['papa']!;
      await sync(
        mama,
        changes: [
          doc('x', {
            'title': 'x',
            'visibleTo': [papaId],
          }),
        ],
      );
      final mine = (await sync(mama)).changes.single;
      expect(mine.visibleTo, unorderedEquals([papaId, mamaId]));
    });

    test(
      'members cannot overwrite or delete records hidden from them',
      () async {
        final f = await family();
        final (mama, mamaId) = f['mama']!;
        final (kind, _) = f['kind']!;
        await sync(
          mama,
          changes: [
            doc('privat', {
              'title': 'Tagebuch',
              'visibleTo': [mamaId],
            }),
          ],
        );

        // Guessing the id and writing a newer version must not work …
        final answer = await sync(
          kind,
          changes: [
            doc('privat', {'title': 'Gehackt'}),
            doc('privat', {}, deleted: true),
          ],
        );
        // … and must not reveal the record either.
        expect(answer.rejected, isEmpty);
        expect(answer.changes.where((c) => c.id == 'privat'), isEmpty);

        final still = (await sync(
          mama,
        )).changes.singleWhere((c) => c.id == 'privat');
        expect(still.data['title'], 'Tagebuch');
        expect(still.deleted, isFalse);
      },
    );

    test(
      'revoking access sends a tombstone, re-granting sends the record',
      () async {
        final f = await family();
        final (mama, mamaId) = f['mama']!;
        final (papa, papaId) = f['papa']!;
        final (kind, _) = f['kind']!;
        await sync(
          mama,
          changes: [
            doc('d', {'title': 'Zeugnis'}),
          ],
        );
        final seen = await sync(kind);
        expect(seen.changes.single.data['title'], 'Zeugnis');

        // Restrict to the parents: the child gets a tombstone that beats any
        // local (even offline-edited) copy.
        await sync(
          mama,
          changes: [
            doc('d', {
              'title': 'Zeugnis',
              'visibleTo': [mamaId, papaId],
            }),
          ],
        );
        final revoked = await sync(kind, since: seen.rev);
        final tomb = revoked.changes.single;
        expect(tomb.deleted, isTrue);
        expect(tomb.data, isEmpty);
        expect(tomb.updatedAt, RecordStore.revokedAt);
        expect(
          (await sync(papa, since: seen.rev)).changes.single.deleted,
          isFalse,
        );

        // Visible to everyone again: the child receives the record.
        await sync(
          mama,
          changes: [
            doc('d', {'title': 'Zeugnis (alle)'}),
          ],
        );
        final back = await sync(kind, since: revoked.rev);
        expect(back.changes.single.data['title'], 'Zeugnis (alle)');
        expect(back.changes.single.deleted, isFalse);
      },
    );

    test('deleting a restricted record only informs its audience', () async {
      final f = await family();
      final (mama, mamaId) = f['mama']!;
      final (kind, _) = f['kind']!;
      await sync(
        mama,
        changes: [
          doc('p', {
            'title': 'p',
            'visibleTo': [mamaId],
          }),
        ],
      );
      final before = await sync(kind);
      await sync(mama, changes: [doc('p', {}, deleted: true)]);
      expect((await sync(kind, since: before.rev)).changes, isEmpty);
    });
  });

  group('files', () {
    List<int> png() => img.encodePng(img.Image(width: 2000, height: 1000));

    test('upload, download and thumbnails', () async {
      final f = await family();
      final (mama, _) = f['mama']!;
      final upload = await send(
        'POST',
        'api/files?name=Foto%20Strand.png',
        token: mama,
        body: png(),
        headers: {'content-type': 'image/png'},
      );
      expect(upload.statusCode, 201);
      final meta = json(upload);
      expect(meta['name'], 'Foto Strand.png');

      final full = await send('GET', 'api/files/${meta['id']}', token: mama);
      expect(full.statusCode, 200);
      expect(full.headers['content-type'], 'image/png');
      expect(full.bodyBytes, png());

      final thumb = await send(
        'GET',
        'api/files/${meta['id']}?thumb=480',
        token: mama,
      );
      expect(thumb.headers['content-type'], 'image/jpeg');
      final decoded = img.decodeJpg(thumb.bodyBytes)!;
      expect((decoded.width, decoded.height), (480, 240));
    });

    test('access follows the visibility of referencing records', () async {
      final f = await family();
      final (mama, mamaId) = f['mama']!;
      final (papa, papaId) = f['papa']!;
      final (kind, _) = f['kind']!;
      final id = json(
        await send(
          'POST',
          'api/files?name=pass.pdf',
          token: mama,
          body: utf8.encode('%PDF-1.7 test'),
          headers: {'content-type': 'application/pdf'},
        ),
      )['id'];

      // Not referenced yet: only the uploader.
      expect((await send('GET', 'api/files/$id', token: papa)).statusCode, 404);

      await sync(
        mama,
        changes: [
          doc('ausweis', {
            'title': 'Reisepass',
            'fileId': id,
            'visibleTo': [mamaId, papaId],
          }),
        ],
      );
      expect((await send('GET', 'api/files/$id', token: papa)).statusCode, 200);
      expect((await send('GET', 'api/files/$id', token: kind)).statusCode, 404);
      expect((await send('GET', 'api/files/$id')).statusCode, 401);
    });

    test('size limit and garbage collection', () async {
      final small = FamioServerApp(
        db: openFamioDatabase(':memory:'),
        location: app.location,
        dataDir: Directory.systemTemp.createTempSync('famio_gc_').path,
        maxUploadMb: 1,
      );
      final s = await io.serve(small.handler, InternetAddress.loopbackIPv4, 0);
      final b = Uri.parse('http://localhost:${s.port}/');
      final token =
          json(
                await http.post(
                  b.resolve('api/auth/setup'),
                  headers: {'content-type': 'application/json'},
                  body: jsonEncode({
                    'username': 'mama',
                    'password': 'geheim123',
                    'setupCode': small.setupCode,
                  }),
                ),
              )['token']
              as String;

      final big = await http.post(
        b.resolve('api/files?name=big.bin'),
        headers: {'authorization': 'Bearer $token'},
        body: List.filled(2 * 1024 * 1024, 1),
      );
      expect(big.statusCode, 413);

      final ok = json(
        await http.post(
          b.resolve('api/files?name=a.txt'),
          headers: {'authorization': 'Bearer $token'},
          body: 'hallo',
        ),
      );
      // Pretend the upload is old and unreferenced.
      small.db.execute('UPDATE files SET created_at = 0');
      expect(small.files.collectGarbage(), 1);
      expect(small.files.get(ok['id'] as String), isNull);
      await s.close(force: true);
      await small.close();
    });
  });

  group('internet exposure', () {
    test('password guessing gets throttled', () async {
      await family();
      Future<int> attempt(String pw) async => (await send(
        'POST',
        'api/auth/login',
        body: {'username': 'papa', 'password': pw},
      )).statusCode;
      for (var i = 0; i < 5; i++) {
        expect(await attempt('falsch$i'), 401);
      }
      expect(await attempt('geheim123'), 429); // Even the right one waits.
      // Other users are not affected.
      expect(
        (await send(
          'POST',
          'api/auth/login',
          body: {'username': 'kind', 'password': 'geheim123'},
        )).statusCode,
        200,
      );
    });

    test('first setup always needs the setup code', () async {
      const proxied = {'x-forwarded-for': '203.0.113.9'};
      final health = json(await send('GET', 'api/health', headers: proxied));
      expect(health['setupCodeRequired'], isTrue);
      expect(
        json(await send('GET', 'api/health'))['setupCodeRequired'],
        isTrue,
      );

      final localDenied = await send(
        'POST',
        'api/auth/setup',
        body: {'username': 'eve', 'password': 'geheim123'},
      );
      expect(localDenied.statusCode, 403);

      final denied = await send(
        'POST',
        'api/auth/setup',
        headers: proxied,
        body: {
          'username': 'eve',
          'password': 'geheim123',
          'setupCode': 'RATEMAL1',
        },
      );
      expect(denied.statusCode, 403);

      final allowed = await send(
        'POST',
        'api/auth/setup',
        headers: proxied,
        body: {
          'username': 'mama',
          'password': 'geheim123',
          'setupCode': app.setupCode!.toLowerCase(),
        },
      );
      expect(allowed.statusCode, 200);
    });

    test('private address detection', () {
      bool private(String a) => ClientAddress.isPrivate(InternetAddress(a));
      expect(private('192.168.1.5'), isTrue);
      expect(private('172.17.0.1'), isTrue);
      expect(private('10.0.0.1'), isTrue);
      expect(private('127.0.0.1'), isTrue);
      expect(private('::1'), isTrue);
      expect(private('fd00::1'), isTrue);
      expect(private('::ffff:192.168.1.2'), isTrue);
      expect(private('203.0.113.9'), isFalse);
      expect(private('172.32.0.1'), isFalse);
      expect(private('2001:db8::1'), isFalse);
    });
  });
}
