import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

bool containsText(String path, String text) => [
  for (final suffix in ['', '-wal'])
    if (File('$path$suffix').existsSync())
      latin1.decode(File('$path$suffix').readAsBytesSync()),
].any((s) => s.contains(text));

void main() {
  setUpAll(FamioServerApp.initTimeZones);

  test(
    'an existing owner-only key is accepted without changing it',
    () {
      final dir = Directory.systemTemp.createTempSync('famio_key').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final keyFile = File('$dir/ro/famio.key')
        ..createSync(recursive: true)
        ..writeAsStringSync('${'ab' * 32}\n');
      // The installer's 0400 in a read-only directory, as under systemd's
      // ProtectSystem=strict: no chmod may be attempted.
      Process.runSync('chmod', ['400', keyFile.path]);
      Process.runSync('chmod', ['500', keyFile.parent.path]);
      addTearDown(() => Process.runSync('chmod', ['700', keyFile.parent.path]));
      expect(loadOrCreateDataKey(keyFile.path, dataDir: dir), 'ab' * 32);
      expect(FileStat.statSync(keyFile.path).mode & 0x1ff, 0x100); // 0400

      Process.runSync('chmod', ['700', keyFile.parent.path]);
      Process.runSync('chmod', ['644', keyFile.path]);
      expect(
        () => loadOrCreateDataKey(keyFile.path, dataDir: dir),
        throwsA(isA<DataKeyException>()),
      );
    },
    testOn: '!windows',
  );

  test('a plain database from an older version is encrypted in place', () {
    final dir = Directory.systemTemp.createTempSync('famio_enc_').path;
    final path = '$dir/famio.db';
    openFamioDatabase(path)
      ..execute(
        "INSERT INTO records (collection, id, data, updated_at, rev)"
        " VALUES ('children', 'c1', '{\"name\":\"Impfpass-Mia\"}', 1, 1)",
      )
      ..close();
    expect(containsText(path, 'Impfpass-Mia'), isTrue);

    final key = loadOrCreateDataKey('$dir/keys/famio.key', dataDir: dir);
    if (!Platform.isWindows) {
      expect(FileStat.statSync('$dir/keys/famio.key').mode & 0x1ff, 0x180);
    }
    final db = openFamioDatabase(path, hexKey: key);
    expect(
      db.select('SELECT data FROM records').single['data'],
      contains('Mia'),
    );
    db.close();
    expect(containsText(path, 'Impfpass-Mia'), isFalse);
    expect(isPlainSqlite(File(path)), isFalse);

    // Same key again: readable. Wrong key: refused, not recreated.
    openFamioDatabase(path, hexKey: key).close();
    expect(
      () => openFamioDatabase(path, hexKey: '00' * 32),
      throwsA(isA<DataKeyException>()),
    );
    // Lost key file with encrypted data: no silent new key.
    expect(
      () => loadOrCreateDataKey('$dir/other.key', dataDir: dir),
      throwsA(isA<DataKeyException>()),
    );
  });

  test(
    'uploads are stored encrypted and old plain files are imported',
    () async {
      final dir = Directory.systemTemp.createTempSync('famio_files_').path;
      // A file left by version 0.5 as plain file.
      Directory('$dir/files').createSync();
      File('$dir/files/legacy-id').writeAsStringSync('Arztbrief alt');
      Directory('$dir/thumbs').createSync();

      final key = loadOrCreateDataKey('$dir/k/famio.key', dataDir: dir);
      final app = FamioServerApp(
        db: openFamioDatabase('$dir/famio.db', hexKey: key),
        location: tz.getLocation('Europe/Berlin'),
        dataDir: dir,
        dataKey: key,
      );
      expect(Directory('$dir/files').existsSync(), isFalse);
      expect(Directory('$dir/thumbs').existsSync(), isFalse);
      final server = await io.serve(
        app.handler,
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final base = Uri.parse('http://localhost:${server.port}/');
      final token =
          (jsonDecode(
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
                  as Map)['token']
              as String;
      final big = List<int>.generate(2500000, (i) => i % 251);
      final up = await http.post(
        base.resolve('api/files?name=befund.pdf'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/pdf',
        },
        body: [...utf8.encode('Befund-Klartext'), ...big],
      );
      final id = (jsonDecode(up.body) as Map)['id'];
      final down = await http.get(
        base.resolve('api/files/$id'),
        headers: {'authorization': 'Bearer $token'},
      );
      expect(down.bodyBytes.length, 2500000 + 15);
      expect(utf8.decode(down.bodyBytes.sublist(0, 15)), 'Befund-Klartext');
      expect(down.bodyBytes.sublist(15), big);
      expect(containsText('$dir/files.db', 'Befund-Klartext'), isFalse);

      // The imported legacy file is served from the block storage.
      final legacy = app.files.blobs.select(
        "SELECT count(*) FROM blobs WHERE id = 'legacy-id'",
      );
      expect(legacy.single.columnAt(0), 1);
      await app.close();
    },
  );

  test('requireTls refuses plain API access from the network', () async {
    final app = FamioServerApp(
      db: openFamioDatabase(':memory:'),
      location: tz.getLocation('Europe/Berlin'),
      dataDir: Directory.systemTemp.createTempSync('famio_tls_').path,
      blobs: sqlite3.openInMemory(),
      requireTls: true,
      trustProxy: true,
      tlsPort: 8766,
    );
    // This machine itself (loopback) is always allowed.
    final server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = Uri.parse('http://localhost:${server.port}/');
    expect((await http.get(base.resolve('api/health'))).statusCode, 200);
    expect((await http.get(base.resolve('api/me'))).statusCode, 401);

    // From another machine (simulated by an external interface address).
    final lan = await _lanAddress();
    if (lan == null) return; // No network interface in this environment.
    final open = await io.serve(app.handler, lan, 0);
    addTearDown(() => open.close(force: true));
    final remote = Uri.parse('http://${lan.address}:${open.port}/');
    final refused = await http.get(remote.resolve('api/me'));
    expect(refused.statusCode, 403);
    expect(refused.body, contains('tls_required'));
    final viaProxy = await http.get(
      remote.resolve('api/me'),
      headers: {'x-forwarded-proto': 'https'},
    );
    expect(viaProxy.statusCode, 401); // Passed the guard, needs a login.
  });
}

Future<InternetAddress?> _lanAddress() async {
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a;
    }
  }
  return null;
}
