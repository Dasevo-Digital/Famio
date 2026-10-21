import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;
  final asked = <String>[];
  final uploads = <Map<String, Object?>>[];
  var shareOpen = true;

  /// PhotoVault as its server answers (packages/server of PhotoVault).
  final photoVault = MockClient((request) async {
    final path = request.url.path;
    asked.add('${request.method} $path');
    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
    Map<String, Object?> image(String id, String taken) => {
      'id': id,
      'art': 'bild',
      'name': '$id.jpg',
      'aufgenommen': taken,
    };
    // The share links work without an account.
    if (path == '/api/v1/teilen/L1' || path == '/api/v1/teilen/L2') {
      if (path.endsWith('L2') &&
          request.headers['cookie'] != 'pv_teilen_2=ok') {
        return json({'passwort': true}, 401);
      }
      return json({'titel': 'Familie', 'hochladen': shareOpen});
    }
    if (path == '/api/v1/teilen/L2/passwort') {
      final ok = (jsonDecode(request.body) as Map)['passwort'] == 'geheim';
      return ok
          ? http.Response(
              '',
              204,
              headers: {'set-cookie': 'pv_teilen_2=ok; Path=/; HttpOnly'},
            )
          : json({'fehler': 'Passwort falsch'}, 401);
    }
    if (path == '/api/v1/teilen/L1/beitrag') {
      expect(request.headers['x-pv-teilen'], '1');
      uploads.add({
        ...request.url.queryParameters,
        'bytes': utf8.decode(request.bodyBytes),
      });
      return json({'id': 'b${uploads.length}'}, 202);
    }
    switch (path) {
      case '/api/v1/anmelden':
        final body = jsonDecode(request.body) as Map;
        if (body['passwort'] != 'richtig') {
          return json({'fehler': 'Name, Passwort oder Code stimmt nicht'}, 401);
        }
        expect(body['geraet'], 'Famio');
        return json({'schritt': 'totp', 'vorgang': 'v1'});
      case '/api/v1/anmelden/totp':
        final body = jsonDecode(request.body) as Map;
        if ((body['vorgang'], body['code']) != ('v1', '123456')) {
          return json({'fehler': 'Name, Passwort oder Code stimmt nicht'}, 401);
        }
        return json({
          'token': 'pv1_famio',
          'geraet': {'id': 'g1'},
        });
    }
    if (request.headers['authorization'] != 'Bearer pv1_famio') {
      return json({'fehler': 'nicht angemeldet'}, 401);
    }
    switch (path) {
      case '/api/v1/konto':
        return json({'id': 'k1', 'name': 'familie'});
      case '/api/v1/abmelden':
        return json({'abgemeldet': true});
      case '/api/v1/rueckblick':
        final today = request.url.queryParameters['heute']!;
        return json({
          'letzte': [
            {
              'tag': today,
              'jahreHer': 1,
              'aufnahmen': [
                image('a1', '2025-10-20T10:00:00'),
                {'id': 'v1', 'art': 'video', 'name': 'film.mp4'},
              ],
            },
            {
              'tag': '1999-01-01',
              'jahreHer': 3,
              'aufnahmen': [image('alt', '1996-01-01T10:00:00')],
            },
          ],
        });
      case '/api/v1/bibliothek':
        return json({'schema': 1, 'protokoll': 1, 'aufnahmen': 6});
      case '/api/v1/aufnahmen':
        // The timeline, oldest first, one photo at a place.
        final q = request.url.queryParameters;
        expect((q['sortierung'], q['anzahl']), ('aufnahmeAlt', '1'));
        final at = int.parse(q['nach']!.replaceFirst('o:', ''));
        return json({
          'aufnahmen': [
            if (at == 3)
              {'id': 't3', 'art': 'video', 'name': 'film.mp4'}
            else
              image('t$at', '201$at-01-01T10:00:00'),
          ],
          'weiter': 'o:${at + 1}',
        });
      case '/api/v1/alben':
        return json({
          'alben': [
            {'id': 'al1', 'name': 'Familie', 'anzahl': 2},
          ],
        });
      case '/api/v1/alben/al1':
        return json({
          'album': {'id': 'al1', 'name': 'Familie'},
          'aufnahmen': [
            image('a2', '2024-05-01T12:00:00'),
            image('a1', '2025-10-20T10:00:00'),
          ],
        });
      case '/api/v1/stammbaum':
        Map<String, Object?> person(
          String id,
          String name,
          String born, {
          bool related = true,
          String? died,
        }) => {
          'id': id,
          'name': name,
          'geburt': '${born}T00:00:00.000',
          'tod': died,
          'verwandt': related,
        };
        return json({
          'personen': [
            person('p1', 'Erna Müller', '1950-03-14'),
            person('p2', 'Karl Müller', '1948-07-01', died: '2020-01-01'),
            person('p3', 'Max Freund', '1990-02-02', related: false),
            // Noted already: the child, a contact, a calendar.
            person('p4', 'Mia Beispiel', '2019-06-05'),
            person('p5', 'Paul Meier', '1980-09-09'),
            person('p6', 'Lena Schmidt', '1955-12-24'),
            // Another person on a contact's day: kept.
            person('p7', 'Tom Huber', '1985-04-04'),
          ],
        });
      case '/api/v1/aufnahmen/a1/miniatur':
        return http.Response(
          'JPEG-klein',
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      case '/api/v1/aufnahmen/a1/ansicht':
        return http.Response(
          'JPEG-gross',
          200,
          headers: {'content-type': 'image/jpeg'},
        );
    }
    return http.Response('unexpected ${request.url}', 500);
  });

  setUp(() async {
    asked.clear();
    uploads.clear();
    shareOpen = true;
    app = FamioServerApp.inMemory(httpClient: photoVault);
    final setup = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/setup'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'username': 'mama',
          'password': 'tulpe-regal-7',
          'setupCode': app.setupCode,
        }),
      ),
    );
    token = (jsonDecode(await setup.readAsString()) as Map)['token'] as String;
  });

  tearDown(() => app.close());

  Future<Response> call(
    String method,
    String path, {
    Object? body,
    String? as,
  }) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/$path'),
      headers: {
        'authorization': 'Bearer ${as ?? token}',
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<Map<String, Object?>> ok(Response r) async {
    final text = await r.readAsString();
    expect(r.statusCode, 200, reason: text);
    return (jsonDecode(text) as Map).cast();
  }

  Future<String> member(String username, String role) async {
    await ok(
      await call(
        'POST',
        'api/admin/users',
        body: {
          'username': username,
          'displayName': username,
          'password': 'tulpe-regal-7',
          'role': role,
        },
      ),
    ).catchError((Object _) => <String, Object?>{});
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': username, 'password': 'tulpe-regal-7'}),
      ),
    );
    return (jsonDecode(await r.readAsString()) as Map)['token'] as String;
  }

  Future<void> connect() async {
    final step = await ok(
      await call(
        'POST',
        'api/admin/photovault/connect',
        body: {
          'url': 'https://photos.example.de/',
          'name': 'familie',
          'password': 'richtig',
        },
      ),
    );
    expect(step, {'step': 'totp', 'vorgang': 'v1'});
    final info = await ok(
      await call(
        'POST',
        'api/admin/photovault/connect',
        body: {
          'url': 'https://photos.example.de/',
          'vorgang': 'v1',
          'code': '123 456',
        },
      ),
    );
    expect(
      (info['connected'], info['url'], info['account']),
      (true, 'https://photos.example.de', 'familie'),
    );
    expect(jsonEncode(info), isNot(contains('pv1_')));
  }

  test(
    'A: memories of the day and the album, pictures through Famio',
    () async {
      final mia = await member('mia', 'child');
      final oma = await member('oma', 'guest');
      await connect();
      final info = await ok(
        await call('PUT', 'api/admin/photovault', body: {'albumId': 'al1'}),
      );
      expect(
        (
          info['albumName'],
          info['memoryCount'],
          info['albumCount'],
          info['libraryCount'],
        ),
        ('Familie', 1, 2, 6),
      );

      final a1 = app.records.get(Collections.externalPhotos, 'pv-a1')!;
      final a2 = app.records.get(Collections.externalPhotos, 'pv-a2')!;
      expect(a1.data['memoryOf'], isNotNull);
      expect((a1.data['yearsAgo'], a1.data['album']), (1, true));
      expect((a2.data['memoryOf'], a2.data['album']), (null, true));
      // No videos, nothing of other days.
      expect(app.records.get(Collections.externalPhotos, 'pv-v1'), isNull);
      expect(app.records.get(Collections.externalPhotos, 'pv-alt'), isNull);
      expect(
        a1.visibleTo,
        isNot(
          contains(
            app.accounts.members().firstWhere((m) => m.username == 'oma').id,
          ),
        ),
      );

      final file = FileRef.fromJson(a1.data['file'])!;
      final thumb = await call(
        'GET',
        'api/files/${file.id}?thumb=320',
        as: mia,
      );
      expect(await thumb.readAsString(), 'JPEG-klein');
      final full = await call('GET', 'api/files/${file.id}');
      expect(await full.readAsString(), 'JPEG-gross');
      expect(
        (await call('GET', 'api/files/${file.id}', as: oma)).statusCode,
        404,
      );

      // The album taken away: only today's memory stays.
      await ok(
        await call('PUT', 'api/admin/photovault', body: {'albumId': ''}),
      );
      expect(
        app.records.get(Collections.externalPhotos, 'pv-a2')!.deleted,
        true,
      );
      expect(
        app.records.get(Collections.externalPhotos, 'pv-a1')!.deleted,
        false,
      );

      await ok(await call('DELETE', 'api/admin/photovault'));
      expect(
        app.records.get(Collections.externalPhotos, 'pv-a1')!.deleted,
        true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, contains('POST /api/v1/abmelden'));
    },
  );

  test('A: random photos of the timeline on the wall display', () async {
    await connect();
    List<String> wall() => [
      for (final r in app.records.all(Collections.externalPhotos))
        if (!r.deleted && r.data['album'] == true) r.id,
    ]..sort();
    int places() => asked.where((a) => a == 'GET /api/v1/aufnahmen').length;

    asked.clear();
    final info = await ok(
      await call('PUT', 'api/admin/photovault', body: {'timeline': true}),
    );
    expect((info['timeline'], info['albumCount']), (true, 5));
    // All six places of the small timeline, without the video.
    expect(wall(), ['pv-t0', 'pv-t1', 'pv-t2', 'pv-t4', 'pv-t5']);
    expect(places(), 6);

    // The same photos until they are drawn anew.
    asked.clear();
    await app.photoVault.sync();
    expect(places(), 0);
    app.db.execute(
      "UPDATE settings SET value = json_set(value, '\$.drawnAt', "
      "'2020-01-01T00:00:00Z') WHERE key = 'photovault.timeline'",
    );
    await app.photoVault.sync();
    expect(places(), 6);

    await ok(
      await call('PUT', 'api/admin/photovault', body: {'timeline': false}),
    );
    expect(wall(), isEmpty);
    expect(
      app.db.select("SELECT 1 FROM settings WHERE key = 'photovault.timeline'"),
      isEmpty,
    );
  });

  test('C: birthdays of the family tree not noted anywhere else', () async {
    // What the family has already.
    final now = DateTime.now().millisecondsSinceEpoch;
    await ok(
      await call(
        'POST',
        'api/sync',
        body: SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.children,
              id: 'k1',
              data: Child(
                id: 'k1',
                name: 'Mia',
                birthDate: DateTime(2019, 6, 5),
              ).toData(),
              updatedAt: now,
            ),
            SyncRecord(
              collection: Collections.contacts,
              id: 'c1',
              data: const FamilyContact(
                id: 'c1',
                name: 'Paul',
                birthday: Birthday(9, 9),
              ).toData(),
              updatedAt: now,
            ),
            SyncRecord(
              collection: Collections.contacts,
              id: 'c2',
              data: const FamilyContact(
                id: 'c2',
                name: 'Anna',
                birthday: Birthday(4, 4),
              ).toData(),
              updatedAt: now,
            ),
          ],
        ).toJson(),
      ),
    );
    // A subscribed calendar with "Geburtstag Oma" on Lena's day.
    app.records.writeAsServer([
      SyncRecord(
        collection: Collections.calendarSubscriptions,
        id: 'icloud',
        data: const {'name': 'iCloud Geburtstage'},
        updatedAt: 0,
      ),
      SyncRecord(
        collection: Collections.externalEvents,
        id: 'x1',
        data: CalendarEvent(
          id: 'x1',
          title: '🎂 Geburtstag Oma',
          start: DateTime(2026, 12, 24),
          end: DateTime(2026, 12, 25),
          allDay: true,
          sourceId: 'icloud',
        ).toData(),
        updatedAt: 0,
      ),
    ]);
    await connect();
    final info = await ok(
      await call(
        'PUT',
        'api/admin/photovault',
        body: {'memories': false, 'birthdays': true},
      ),
    );
    final kept = {
      for (final r in app.records.all(Collections.externalBirthdays))
        if (!r.deleted) '${r.data['name']}': r.data['birthday'],
    };
    expect(kept, {'Erna Müller': '1950-03-14', 'Tom Huber': '1985-04-04'});
    final skipped = {
      for (final s in info['skippedBirthdays']! as List)
        '${(s as Map)['name']}': s['reason'],
    };
    expect(skipped, {
      'Mia Beispiel': 'Kind „Mia“',
      'Paul Meier': 'Kontakt „Paul“',
      'Lena Schmidt': 'Kalender „iCloud Geburtstage“: „🎂 Geburtstag Oma“',
    });

    // Noted in Famio later: gone from PhotoVault's at the next sync.
    await ok(
      await call(
        'POST',
        'api/sync',
        body: SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.contacts,
              id: 'c3',
              data: const FamilyContact(
                id: 'c3',
                name: 'Oma Erna',
                birthday: Birthday(3, 14, 1950),
              ).toData(),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ],
        ).toJson(),
      ),
    );
    await ok(await call('POST', 'api/admin/photovault/sync'));
    expect(
      app.records.get(Collections.externalBirthdays, 'pv-p1')!.deleted,
      true,
    );
  });

  test('B: photos of the family chat go to the share link once', () async {
    await connect();
    Future<FileRef> upload(String name) async {
      final r = await app.handler(
        Request(
          'POST',
          Uri.parse('http://famio.test/api/files?name=$name'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'image/jpeg',
          },
          body: 'JPEG $name',
        ),
      );
      final json = jsonDecode(await r.readAsString()) as Map;
      return FileRef(
        id: json['id'] as String,
        name: name,
        mime: 'image/jpeg',
        size: json['size'] as int,
      );
    }

    final me = app.accounts
        .members()
        .firstWhere((m) => m.username == 'mama')
        .id;
    Future<void> send(
      String id,
      String chatId, {
      FileRef? photo,
      DateTime? at,
    }) async {
      await ok(
        await call(
          'POST',
          'api/sync',
          body: SyncRequest(
            since: 0,
            changes: [
              SyncRecord(
                collection: Collections.chatMessages,
                id: id,
                data: ChatMessage(
                  id: id,
                  chatId: chatId,
                  authorId: me,
                  sentAt: at ?? DateTime.now(),
                  text: photo == null ? 'Hallo' : '',
                  attachment: photo,
                ).toData(),
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            ],
          ).toJson(),
        ),
      );
    }

    // Before the link was set: stays out.
    await send(
      'old',
      ChatIds.family,
      photo: await upload('alt.jpg'),
      at: DateTime.now().subtract(const Duration(days: 1)),
    );
    shareOpen = false;
    final closed = await call(
      'PUT',
      'api/admin/photovault',
      body: {'shareUrl': 'https://photos.example.de/teilen/L1'},
    );
    expect(closed.statusCode, 400);
    expect(await closed.readAsString(), contains('keine Beiträge'));
    shareOpen = true;
    await ok(
      await call(
        'PUT',
        'api/admin/photovault',
        body: {
          'memories': false,
          'shareUrl': 'https://photos.example.de/teilen/L1',
        },
      ),
    );
    await send('m1', ChatIds.family, photo: await upload('strand.jpg'));
    await send(
      'm2',
      ChatIds.direct(me, 'x'),
      photo: await upload('privat.jpg'),
    );
    await send('m3', ChatIds.family);
    await ok(await call('POST', 'api/admin/photovault/sync'));
    await ok(await call('POST', 'api/admin/photovault/sync'));
    expect(uploads, hasLength(1));
    expect(
      (uploads.single['name'], uploads.single['von'], uploads.single['bytes']),
      ('strand.jpg', 'mama', 'JPEG strand.jpg'),
    );

    // A link with a password needs it.
    final locked = await call(
      'PUT',
      'api/admin/photovault',
      body: {'shareUrl': 'https://photos.example.de/teilen/L2'},
    );
    expect(await locked.readAsString(), contains('Passwort'));
    final info = await ok(
      await call(
        'PUT',
        'api/admin/photovault',
        body: {
          'shareUrl': 'https://photos.example.de/teilen/L2',
          'sharePassword': 'geheim',
        },
      ),
    );
    expect(
      (info['shareUrl'], info['sharePassword']),
      ('https://photos.example.de/teilen/L2', true),
    );
  });

  test('the duplicate rule', () {
    List<KnownBirthday> known(String text, {bool person = false}) => [
      (
        month: 3,
        day: 14,
        text: text,
        person: person,
        birthdayEntry: !person && text.contains('Geburtstag'),
        where: text,
      ),
    ];
    const erna = Birthday(3, 14, 1950);
    expect(
      noteOf('Erna Müller', erna, known('Oma Erna', person: true)),
      'Oma Erna',
    );
    expect(noteOf('Erna Müller', erna, known('Erna')), 'Erna');
    expect(
      noteOf('Erna Müller', erna, known('Geburtstag Oma')),
      'Geburtstag Oma',
    );
    // Another person, or an appointment, on that day.
    expect(noteOf('Erna Müller', erna, known('Paul', person: true)), isNull);
    expect(noteOf('Erna Müller', erna, known('Zahnarzt')), isNull);
    expect(noteOf('Erna Müller', const Birthday(3, 15), known('Erna')), isNull);
  });
}
