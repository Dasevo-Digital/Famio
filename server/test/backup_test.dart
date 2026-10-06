import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/backup/backup_job.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  late FamioServerApp app;
  late String admin;

  Future<(int, Map)> call(String method, String path, {String? token}) async {
    final r = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/$path'),
        headers: {
          'authorization': ?(token == null ? null : 'Bearer $token'),
          'content-type': 'application/json',
        },
      ),
    );
    final text = await r.readAsString();
    return (r.statusCode, text.isEmpty ? {} : jsonDecode(text) as Map);
  }

  setUp(() async {
    app = FamioServerApp.inMemory();
    final me = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      passwordHash: 'x',
      isAdmin: true,
    );
    admin = app.accounts.createSession(me.id, method: 'password');
    app.records.writeAs(me.id, [
      SyncRecord(
        collection: Collections.tasks,
        id: 't1',
        data: const Task(id: 't1', title: 'Müll').toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
  });

  tearDown(() => app.close());

  test('admins back up while the server runs', () async {
    final (before, status) = await call(
      'GET',
      'api/admin/backups',
      token: admin,
    );
    expect((before, status['enabled']), (200, true));
    expect(status['backups'], isEmpty);
    final (made, backup) = await call(
      'POST',
      'api/admin/backups',
      token: admin,
    );
    expect(made, 201);
    final folder = Directory(
      p.join(app.dataDir, 'backups', backup['name'] as String),
    );
    expect(File(p.join(folder.path, 'files.db')).existsSync(), isTrue);
    final copy = sqlite3.open(p.join(folder.path, 'famio.db'));
    expect(
      copy.select("SELECT id FROM records WHERE collection = 'tasks'"),
      hasLength(1),
    );
    copy.close();
    final (_, after) = await call('GET', 'api/admin/backups', token: admin);
    expect((after['backups'] as List).single['name'], backup['name']);
    expect(after['lastAt'], isNotNull);
  });

  test('keeps a week of days and a month of weeks', () {
    final dir = Directory.systemTemp.createTempSync('famio_backup_');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Two backups a day for 60 days, newest 2026-10-06.
    for (var i = 0; i < 60; i++) {
      final d = DateTime(2026, 10, 6 - i);
      for (final t in ['030000', '120000']) {
        final name =
            'famio-${d.year}${d.month.toString().padLeft(2, '0')}'
            '${d.day.toString().padLeft(2, '0')}-$t';
        Directory(p.join(dir.path, name)).createSync();
      }
    }
    final db = sqlite3.openInMemory();
    BackupJob(db: db, blobs: db, dir: dir.path, location: () => tz.UTC).prune();
    final kept = [for (final e in dir.listSync()) p.basename(e.path)]..sort();
    expect(kept, hasLength(11));
    // The 7 newest days, each with its latest backup …
    expect(kept.where((n) => n.endsWith('120000')), hasLength(11));
    expect(kept.last, 'famio-20261006-120000');
    expect(kept, contains('famio-20260930-120000'));
    // … then one per older week.
    expect(kept, isNot(contains('famio-20260929-120000')));
  });
}
