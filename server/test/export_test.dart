import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String mamaToken;
  late String kindToken;
  late String mama;
  late String kind;

  Future<Response> call(
    String method,
    String path, {
    String? token,
    Object? body,
  }) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/$path'),
      headers: {
        'authorization': ?(token == null ? null : 'Bearer $token'),
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<Map> json(Response r) async =>
      jsonDecode(await r.readAsString()) as Map;

  setUp(() async {
    app = FamioServerApp.inMemory();
    final setup = await json(
      await call(
        'POST',
        'api/auth/setup',
        body: {
          'username': 'mama',
          'password': 'geheim123',
          'setupCode': app.setupCode,
        },
      ),
    );
    mamaToken = setup['token'] as String;
    mama = (setup['member'] as Map)['id'] as String;
    await call(
      'POST',
      'api/admin/users',
      token: mamaToken,
      body: {
        'username': 'kind',
        'displayName': 'Kind',
        'password': 'kindpass123',
        'role': 'child',
      },
    );
    final login = await json(
      await call(
        'POST',
        'api/auth/login',
        body: {'username': 'kind', 'password': 'kindpass123'},
      ),
    );
    kindToken = login['token'] as String;
    kind = (login['member'] as Map)['id'] as String;

    final now = DateTime.now().millisecondsSinceEpoch;
    app.records.writeAs(mama, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'fuer-alle',
        data: const Task(id: 'fuer-alle', title: 'Müll').toData(),
        updatedAt: now,
      ),
      SyncRecord(
        collection: Collections.tasks,
        id: 'geheim',
        data: {
          ...const Task(id: 'geheim', title: 'Geschenk kaufen').toData(),
          SyncRecord.visibilityKey: [mama],
        },
        updatedAt: now,
      ),
    ]);
    await app.files.save(
      owner: kind,
      name: 'bild.jpg',
      mime: 'image/jpeg',
      body: Stream.value([1, 2, 3]),
    );
    app.db.execute(
      'INSERT INTO location_points (member_id, at, latitude, longitude,'
      ' accuracy) VALUES (?, ?, 53.5, 10.0, 12), (?, ?, 48.1, 11.5, 8)',
      [kind, now, mama, now],
    );
  });

  tearDown(() => app.close());

  Future<Archive> unzip(Response r) async {
    final bytes = <int>[];
    await for (final chunk in r.read()) {
      bytes.addAll(chunk);
    }
    return ZipDecoder().decodeBytes(bytes);
  }

  String text(Archive a, String name) =>
      utf8.decode(a.findFile(name)!.content as List<int>);

  List<String> tempFiles() {
    final dir = Directory(p.join(app.dataDir, 'tmp'));
    return dir.existsSync()
        ? [for (final f in dir.listSync()) p.basename(f.path)]
        : const [];
  }

  test('a member exports what they see, after the password', () async {
    final wrong = await call(
      'POST',
      'api/me/export',
      token: kindToken,
      body: {'password': 'falsch'},
    );
    expect(wrong.statusCode, 403);

    final r = await call(
      'POST',
      'api/me/export',
      token: kindToken,
      body: {'password': 'kindpass123'},
    );
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], 'application/zip');
    expect(r.headers['content-disposition'], contains('famio-meine-daten-'));
    final zip = await unzip(r);
    expect(tempFiles(), isEmpty, reason: 'deleted after sending');

    expect(jsonDecode(text(zip, 'famio.json'))['scope'], 'member');
    final tasks = text(zip, 'records/tasks.json');
    expect(tasks, contains('Müll'));
    expect(tasks, isNot(contains('Geschenk')));
    expect(zip.findFile('LIESMICH.txt'), isNotNull);
    expect(
      zip.files.where((f) => f.name.startsWith('files/')).single.name,
      endsWith('-bild.jpg'),
    );
    final location = jsonDecode(text(zip, 'location.json')) as List;
    expect(location.single['latitude'], 53.5);
    expect(zip.findFile('settings.json'), isNull);
    expect(text(zip, 'members.json'), isNot(contains('kindpass123')));
  });

  test('only admins export the family, without location histories', () async {
    final denied = await call(
      'POST',
      'api/admin/export',
      token: kindToken,
      body: {'password': 'kindpass123'},
    );
    expect(denied.statusCode, 403);

    final r = await call(
      'POST',
      'api/admin/export',
      token: mamaToken,
      body: {'password': 'geheim123'},
    );
    expect(r.statusCode, 200);
    final zip = await unzip(r);
    expect(jsonDecode(text(zip, 'famio.json'))['scope'], 'family');
    final tasks = text(zip, 'records/tasks.json');
    expect(tasks, contains('Geschenk'));
    expect(tasks, contains(mama), reason: 'visibility is kept');
    expect(zip.findFile('location.json'), isNull);
    expect(zip.findFile('settings.json'), isNotNull);
    final members = jsonDecode(text(zip, 'members.json')) as List;
    expect(members.map((m) => m['username']), containsAll(['mama', 'kind']));
  });

  test('archives left by a broken download are removed at start', () {
    final dir = Directory(p.join(app.dataDir, 'tmp'))..createSync();
    File(p.join(dir.path, 'export-alt.zip')).writeAsStringSync('x');
    app.exports.cleanUp();
    expect(tempFiles(), isEmpty);
  });
}
