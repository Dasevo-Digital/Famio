import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/backup/backup_check.dart';
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
    // Tried right after it was made.
    final check = after['lastCheck'] as Map;
    expect((check['ok'], check['users'], check['records']), (true, 1, 1));
    expect((after['backups'] as List).single['check']['ok'], isTrue);

    // And again on request, without changing the backup.
    final (checked, again) = await call(
      'POST',
      'api/admin/backups/check',
      token: admin,
    );
    expect((checked, again['ok']), (200, true));
    expect(again['problems'], isEmpty);
    expect([for (final f in folder.listSync()) p.basename(f.path)]..sort(), [
      'check.json',
      'famio.db',
      'files.db',
    ]);
  });

  group('a backup check', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('famio_check_'));
    tearDown(() => dir.deleteSync(recursive: true));

    /// A backup folder like the real ones, encrypted with [key].
    var made = 0;
    String backup({String? key, bool withBlob = true, int users = 1}) {
      final folder = Directory(
        p.join(dir.path, 'famio-20261009-03000${made++}'),
      )..createSync();
      final main = openEncrypted(p.join(folder.path, 'famio.db'), hexKey: key)
        ..execute('CREATE TABLE users (id TEXT)')
        ..execute('CREATE TABLE records (deleted INTEGER)')
        ..execute('CREATE TABLE files (id TEXT)')
        ..execute("INSERT INTO files VALUES ('f1')")
        ..execute('INSERT INTO records VALUES (0), (0), (1)');
      for (var i = 0; i < users; i++) {
        main.execute("INSERT INTO users VALUES ('u$i')");
      }
      main.close();
      final blobs = openEncrypted(p.join(folder.path, 'files.db'), hexKey: key)
        ..execute(
          'CREATE TABLE blobs (id TEXT, kind TEXT, seq INTEGER, data BLOB)',
        );
      if (withBlob) {
        blobs.execute("INSERT INTO blobs VALUES ('f1', 'f', 0, x'00')");
      }
      blobs.close();
      return folder.path;
    }

    final key = 'ab' * 32;

    test('passes an intact encrypted backup', () {
      final folder = backup(key: key);
      final c = checkBackup(folder, hexKey: key, liveUsers: 1, liveRecords: 2);
      expect(
        (c.ok, c.users, c.records, c.files, c.filesChecked),
        (true, 1, 2, 1, true),
      );
      expect(Directory(folder).listSync(), hasLength(2));
    });

    test('reads a copy of a WAL database without leaving files', () {
      final source = openEncrypted(p.join(dir.path, 'live.db'), hexKey: key)
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('CREATE TABLE users (id TEXT)')
        ..execute('CREATE TABLE records (deleted INTEGER)')
        ..execute('CREATE TABLE files (id TEXT)')
        ..execute("INSERT INTO users VALUES ('u')");
      final folder = Directory(p.join(dir.path, 'famio-20261009-040000'))
        ..createSync();
      source.execute("VACUUM INTO '${p.join(folder.path, 'famio.db')}'");
      source.close();
      final c = checkBackup(
        folder.path,
        hexKey: key,
        liveUsers: 1,
        liveRecords: 0,
      );
      expect((c.ok, c.users, c.filesChecked), (true, 1, false));
      expect(
        [for (final f in folder.listSync()) p.basename(f.path)],
        ['famio.db'],
      );
    });

    test('names what is wrong', () {
      final folder = backup(key: key, withBlob: false);
      expect(
        checkBackup(folder, hexKey: key, liveUsers: 1, liveRecords: 2).problems,
        ['1 Datei ohne Inhalt in files.db'],
      );
      final wrongKey = checkBackup(
        folder,
        hexKey: 'cd' * 32,
        liveUsers: 1,
        liveRecords: 2,
      );
      expect(wrongKey.ok, isFalse);
      expect(wrongKey.problems.first, contains('Datenschlüssel'));
      File(p.join(folder, 'famio.db')).writeAsStringSync('kaputt');
      expect(
        checkBackup(folder, hexKey: key, liveUsers: 1, liveRecords: 2).ok,
        isFalse,
      );
    });

    test('notes a backup with far fewer entries, wants members', () {
      final folder = backup(users: 0);
      final c = checkBackup(
        folder,
        hexKey: null,
        liveUsers: 2,
        liveRecords: 500,
      );
      expect(c.problems, ['Keine Mitglieder in der Sicherung']);
      final fine = checkBackup(
        backup(),
        hexKey: null,
        liveUsers: 1,
        liveRecords: 500,
      );
      expect(fine.ok, isTrue);
      expect(fine.notes.single, contains('2 statt 500'));
    });
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

  test('documents and photos stay only in the newest backups', () async {
    final dir = Directory.systemTemp.createTempSync('famio_backup_files_');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final day in ['20261004', '20261005', '20261006']) {
      final b = Directory(p.join(dir.path, 'famio-$day-030000'))..createSync();
      File(p.join(b.path, 'famio.db')).writeAsStringSync('x');
      File(p.join(b.path, 'files.db')).writeAsStringSync('x');
    }
    final db = sqlite3.openInMemory();
    final job = BackupJob(
      db: db,
      blobs: db,
      dir: dir.path,
      location: () => tz.UTC,
    )..prune();
    final backups = job.list();
    expect(backups, hasLength(3));
    bool has(BackupInfo b, String f) =>
        File(p.join(dir.path, b.name, f)).existsSync();
    expect([for (final b in backups) has(b, 'files.db')], [true, true, false]);
    expect([for (final b in backups) has(b, 'famio.db')], everyElement(isTrue));
    expect(await BackupJob.freeBytes(dir.path), greaterThan(0));
  });

  test('the copy runs beside the server (file databases)', () async {
    // files.db of the test app is a real file: copied in an isolate.
    final backup = await app.backups!.run();
    final copy = sqlite3.open(
      p.join(app.backups!.dir, backup.name, 'files.db'),
    );
    expect(copy.select('SELECT name FROM sqlite_master'), isNotEmpty);
    copy.close();
    expect(backup.check?.ok, isTrue);
  });
}
