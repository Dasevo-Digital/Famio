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
      'created-at',
      'famio.db',
      'file-scope',
      'files.db',
    ]);
  });

  test('the latest backup must still contain its file database', () async {
    await app.files.save(
      owner: app.accounts.members().single.id,
      name: 'fixture.txt',
      mime: 'text/plain',
      body: Stream.value([1, 2, 3]),
    );
    final (made, backup) = await call(
      'POST',
      'api/admin/backups',
      token: admin,
    );
    expect(made, 201);
    final folder = app.backups!.folder(backup['name'] as String)!;

    Future<bool> setupDone() async {
      final (code, checklist) = await call(
        'GET',
        'api/admin/setup',
        token: admin,
      );
      expect(code, 200);
      return (checklist['steps'] as List).singleWhere(
            (step) => step['id'] == 'backup',
          )['done']
          as bool;
    }

    expect(await setupDone(), isTrue);
    File(p.join(folder.path, 'files.db')).deleteSync();
    expect(
      await setupDone(),
      isFalse,
      reason: 'cached check predates the loss',
    );

    final (checked, result) = await call(
      'POST',
      'api/admin/backups/check',
      token: admin,
    );
    expect(checked, 200);
    expect(
      (result['ok'], result['filesChecked'], result['files']),
      (false, false, 1),
    );
    expect(result['problems'], ['files.db fehlt']);
    expect(await setupDone(), isFalse);
  });

  test('contents the running data lacks: the database is still backed up, '
      'the fault is reported and the intact copy stays (#572)', () async {
    final attachment = await app.files.save(
      owner: app.accounts.members().single.id,
      name: 'fixture.txt',
      mime: 'text/plain',
      body: Stream.value([1, 2, 3]),
    );
    final (made, original) = await call(
      'POST',
      'api/admin/backups',
      token: admin,
    );
    expect(made, 201);
    final name = original['name'] as String;
    final oldFolder = app.backups!.folder(name)!;
    // As after restoring an older backup without files.db: famio.db names
    // a file whose blocks the files of today no longer have.
    app.files.blobs.execute('DELETE FROM blobs WHERE id = ?', [attachment.id]);
    expect((await app.backups!.verify(name)).ok, isTrue);

    final (kept, flawed) = await call(
      'POST',
      'api/admin/backups',
      token: admin,
    );
    expect(kept, 201);
    expect(flawed['check']['ok'], isFalse);
    expect(flawed['check']['problems'], ['1 Datei ohne Inhalt in files.db']);
    expect(
      flawed['check']['notes'].single,
      contains('fehlen schon in den laufenden Daten'),
    );
    final copy = sqlite3.open(
      p.join(app.backups!.folder(flawed['name'] as String)!.path, 'famio.db'),
    );
    expect(
      copy.select("SELECT id FROM records WHERE collection = 'tasks'"),
      hasLength(1),
    );
    copy.close();

    final (_, status) = await call('GET', 'api/admin/backups', token: admin);
    expect(
      [for (final b in status['backups'] as List) b['name']],
      [flawed['name'], name],
    );
    expect(status['lastCheck']['ok'], isFalse);
    expect(
      status['lastError'],
      'In den laufenden Daten fehlt der Inhalt einer Datei.',
    );
    final (_, checklist) = await call('GET', 'api/admin/setup', token: admin);
    final step = (checklist['steps'] as List).singleWhere(
      (s) => s['id'] == 'backup',
    );
    expect(step['done'], isFalse);
    expect(step['detail'], contains('1 Datei ohne Inhalt in files.db'));
    expect(oldFolder.existsSync(), isTrue);
    final intact = await app.backups!.verify(name);
    expect((intact.ok, intact.filesChecked), (true, true));
  });

  test('a fault of the copy itself still discards it', () async {
    final attachment = await app.files.save(
      owner: app.accounts.members().single.id,
      name: 'fixture.txt',
      mime: 'text/plain',
      body: Stream.value([1, 2, 3]),
    );
    final good = await app.backups!.run();
    // The file database the copy is made from lacks a file that the
    // running data has: that is the copy's fault, not the data's.
    final broken = p.join(app.dataDir, 'broken-files.db');
    app.files.blobs.execute("VACUUM INTO '$broken'");
    final source = sqlite3.open(broken)
      ..execute('DELETE FROM blobs WHERE id = ?', [attachment.id]);
    source.close();
    final job = BackupJob(
      db: app.db,
      blobs: app.files.blobs,
      blobsPath: broken,
      dir: app.backups!.dir,
      location: () => tz.UTC,
    );
    await expectLater(job.run(), throwsA(anything));
    expect(job.lastError, contains('1 Datei ohne Inhalt'));
    expect(job.lastCheck?.ok, isFalse);
    expect(job.list().map((b) => b.name), [good.name]);
    expect(Directory(job.dir).listSync(), hasLength(1));
  });

  BackupJob jobAt(
    DateTime Function() clock, {
    tz.Location? zone,
    int filesKeep = 2,
  }) => BackupJob(
    db: app.db,
    blobs: app.files.blobs,
    dir: app.backups!.dir,
    location: () => zone ?? tz.UTC,
    clock: clock,
    filesKeep: filesKeep,
  );

  Future<void> lacking() async {
    final f = await app.files.save(
      owner: app.accounts.members().single.id,
      name: 'alt.txt',
      mime: 'text/plain',
      body: Stream.value([1, 2, 3]),
    );
    app.files.blobs.execute('DELETE FROM blobs WHERE id = ?', [f.id]);
  }

  test('the nightly run tries the same fault again only after six hours '
      '(#572)', () async {
    var now = DateTime.utc(2026, 11, 20, 4);
    final job = jobAt(() => now);
    addTearDown(job.stop);
    await lacking();
    // Each start() looks once whether a backup is due, as the timer does.
    Future<bool> tick() async {
      job.start();
      final tried = job.running;
      while (job.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return tried;
    }

    expect(await tick(), isTrue);
    final first = job.list().single;
    expect(first.check?.ok, isFalse);
    expect(
      File(p.join(job.folder(first.name)!.path, 'famio.db')).existsSync(),
      isTrue,
    );
    now = now.add(const Duration(minutes: 30));
    expect(await tick(), isTrue, reason: 'the first retry after half an hour');
    final second = now;
    for (final later in [30, 90, 330]) {
      now = second.add(Duration(minutes: later));
      expect(await tick(), isFalse, reason: 'same fault, $later min later');
    }
    now = second.add(const Duration(hours: 6));
    expect(await tick(), isTrue);
    // Only the newest of the day stays of the flawed ones.
    expect(job.list(), hasLength(1));
  });

  test('a failed check counts for no day but the backup stays its term, '
      'with files.db where it is the only intact one (#572)', () async {
    var now = DateTime.utc(2026, 11, 17, 9, 10, 11);
    BackupJob job() => BackupJob(
      db: app.db,
      blobs: app.files.blobs,
      dir: app.backups!.dir,
      location: () => tz.UTC,
      clock: () => now,
      daily: 2,
      weekly: 0,
      filesKeep: 1,
    );
    Future<BackupInfo> nextDay() {
      now = now.add(const Duration(days: 1));
      return job().run();
    }

    final day1 = await job().run();
    final day2 = await nextDay();
    // Its files.db goes missing (disk, by hand); famio.db is still fine.
    File(p.join(job().folder(day2.name)!.path, 'files.db')).deleteSync();
    final recheck = await job().verify(day2.name);
    expect(recheck.ok, isFalse);
    expect(recheck.problems, ['files.db fehlt']);
    final day3 = await nextDay();
    // Day 2 fills no day: days 3 and 1 are the two days, and day 2 stays
    // as long as it would were it fine.
    expect(job().list().map((b) => b.name), [day3.name, day2.name, day1.name]);
    expect((await job().verify(day2.name)).ok, isFalse);

    await lacking();
    final day4 = await nextDay();
    expect(day4.check?.ok, isFalse);
    // Day 2's term (the two newest days of all backups) is over.
    expect(job().list().map((b) => b.name), [day4.name, day3.name, day1.name]);
    // Day 3 is the newest fully intact backup: it keeps its files.db,
    // although otherwise only the newest one does.
    var intact = await job().verify(day3.name);
    expect((intact.ok, intact.filesChecked), (true, true));

    final day5 = await nextDay();
    final day6 = await nextDay();
    expect(job().list().map((b) => b.name), [
      day6.name,
      day5.name,
      day3.name,
      day1.name,
    ]);
    intact = await job().verify(day3.name);
    expect((intact.ok, intact.filesChecked), (true, true));
  });

  test(
    'three backups in the same second retain the newest complete copy',
    () async {
      final now = DateTime.utc(2026, 11, 18, 9, 10, 11);
      final firstJob = jobAt(() => now);
      final first = await firstJob.run();
      expect(first.name, 'famio-20261118-091011');

      final second = await firstJob.run();
      expect(second.name, '${first.name}-000001');
      expect(firstJob.list().map((b) => b.name), [second.name]);
      expect(firstJob.folder(first.name), isNull);

      // An empty in-memory counter could reuse the now-absent first name.
      final restartedJob = jobAt(() => now);
      final third = await restartedJob.run();
      expect(third.name, '${first.name}-000002');
      expect(restartedJob.list().map((b) => b.name), [third.name]);
      expect(third.at, now);
      expect(third.check?.ok, isTrue);
      final saved = restartedJob.folder(third.name)!;
      expect([for (final f in saved.listSync()) p.basename(f.path)]..sort(), [
        'check.json',
        'created-at',
        'famio.db',
        'file-scope',
        'files.db',
      ]);
      expect(Directory(restartedJob.dir).listSync(), hasLength(1));
    },
  );

  test('retention keeps the later instant across the repeated hour', () async {
    final berlin = tz.getLocation('Europe/Berlin');
    var now = DateTime.utc(2026, 10, 25, 0, 55, 43);
    final earlier = await jobAt(() => now, zone: berlin).run();
    expect(earlier.name, 'famio-20261025-025543');
    const firstHour = Duration(hours: 2);
    expect(berlin.timeZone(now.millisecondsSinceEpoch).offset, firstHour);

    // The local clock goes backwards, and the first timestamp must still
    // be available from disk when the server has restarted.
    now = DateTime.utc(2026, 10, 25, 1, 5, 43);
    final restarted = jobAt(() => now, zone: berlin);
    final later = await restarted.run();
    expect(earlier.at.toUtc(), DateTime.utc(2026, 10, 25, 0, 55, 43));
    expect(later.name, 'famio-20261025-020543');
    expect(later.at.toUtc(), now);
    expect(later.check?.ok, isTrue);
    expect(restarted.status()['lastAt'], now.toIso8601String());
    expect(restarted.list().map((b) => b.name), [later.name]);
    expect(restarted.folder(earlier.name), isNull);
    expect(jobAt(() => now, zone: berlin).list().single.at.toUtc(), now);
  });

  for (final legacy in [true, false]) {
    test(
      'timestamp must match the wall time, UTC-only format=$legacy',
      () async {
        var now = DateTime.utc(2026, 11, 18, 9, 10, 11);
        final job = jobAt(() => now);
        final older = await job.run();
        final stamp = File(p.join(job.folder(older.name)!.path, 'created-at'));
        final incorrect = now.toIso8601String().replaceFirst(
          'T09:10:',
          'T09:50:',
        );
        stamp.writeAsStringSync(legacy ? incorrect : '$incorrect\n0');
        expect(job.list().single.at, now);
        now = DateTime.utc(2026, 11, 18, 9, 20, 11);
        final newer = await job.run();
        expect(job.list().single.name, newer.name);
        expect(job.folder(older.name), isNull);
      },
    );
  }

  test('the original offset survives a change of family zone', () async {
    var now = DateTime.utc(2026, 10, 25, 0, 55);
    final berlin = tz.getLocation('Europe/Berlin');
    final earlier = await jobAt(() => now, zone: berlin).run();
    final utc = jobAt(() => now);
    expect(utc.list().single.at, now);
    now = DateTime.utc(2026, 10, 25, 1, 5);
    final later = await utc.run();
    expect(utc.list().single.name, later.name);
    expect(utc.folder(earlier.name), isNull);
  });

  test('a clock correction does not remove a just verified copy', () async {
    var now = DateTime.utc(2026, 11, 18, 9, 20, 11);
    final job = jobAt(() => now, filesKeep: 1);
    final earlier = await job.run();
    now = now.subtract(const Duration(minutes: 15));
    final later = await job.run();
    expect(job.list().map((backup) => backup.name), [earlier.name, later.name]);
    final current = job.folder(later.name)!;
    expect(File(p.join(current.path, 'files.db')).existsSync(), isTrue);
    expect((await job.verify(later.name)).ok, isTrue);
  });

  test('an ambiguous legacy name cannot displace a new backup', () async {
    final berlin = tz.getLocation('Europe/Berlin');
    final now = DateTime.utc(2026, 10, 25, 1, 5, 43);
    final job = jobAt(() => now, zone: berlin);
    final legacy = Directory(p.join(job.dir, 'famio-20261025-025543'))
      ..createSync(recursive: true);
    expect(job.list().single.at.toUtc(), DateTime.utc(2026, 10, 25, 0, 55, 43));

    final later = await job.run();
    expect(job.list().single.name, later.name);
    expect(legacy.existsSync(), isFalse);
  });

  test(
    'listing, verification and retention also work with mixed names',
    () async {
      var now = DateTime.utc(2026, 11, 17, 9, 10, 11);
      final job = jobAt(() => now, filesKeep: 1);
      final legacy = await job.run();
      final legacyFolder = job.folder(legacy.name)!;
      final timestamp = File(p.join(legacyFolder.path, 'created-at'));
      timestamp.deleteSync();
      now = now.add(const Duration(days: 1));
      await job.run();
      final newest = await job.run();

      expect(job.list().map((b) => b.name), [newest.name, legacy.name]);
      expect(job.list().last.at, legacy.at);
      timestamp.writeAsBytesSync([0xff]);
      expect(job.list().last.at, legacy.at);
      expect(File(p.join(legacyFolder.path, 'famio.db')).existsSync(), isTrue);
      expect(File(p.join(legacyFolder.path, 'files.db')).existsSync(), isFalse);
      expect((await job.verify(legacy.name)).ok, isTrue);
      final check = await job.verify(newest.name);
      expect((check.ok, check.filesChecked), (true, true));
    },
  );

  test(
    'missing file contents are not marked as pruned after ageing out',
    () async {
      var now = DateTime.utc(2026, 11, 17, 9, 10, 11);
      final job = jobAt(() => now, filesKeep: 1);
      final full = await job.run();
      File(p.join(job.folder(full.name)!.path, 'files.db')).deleteSync();
      now = now.add(const Duration(days: 1));
      await job.run();

      final afterRestart = jobAt(() => now, filesKeep: 1);
      final check = await afterRestart.verify(full.name);
      expect((check.ok, check.filesChecked), (false, false));
      expect(check.problems, ['files.db fehlt']);
    },
  );

  test(
    'intentional pruning and legacy data-only backups can be checked',
    () async {
      var now = DateTime.utc(2026, 11, 17, 9, 10, 11);
      final job = jobAt(() => now, filesKeep: 1);
      final full = await job.run();
      final olderFolder = job.folder(full.name)!;
      final scope = File(p.join(olderFolder.path, 'file-scope'));
      expect(scope.readAsStringSync(), 'full\n');
      now = now.add(const Duration(days: 1));
      final newest = await job.run();
      expect(scope.readAsStringSync(), 'pruned\n');

      final restarted = jobAt(() => now, filesKeep: 1);
      final intended = await restarted.verify(full.name);
      expect((intended.ok, intended.filesChecked), (true, false));
      scope.deleteSync();
      final legacy = await restarted.verify(full.name);
      expect((legacy.ok, legacy.filesChecked), (true, false));
      final latestFolder = job.folder(newest.name)!;
      File(p.join(latestFolder.path, 'file-scope')).deleteSync();
      File(p.join(latestFolder.path, 'files.db')).deleteSync();
      final missing = await restarted.verify(newest.name);
      expect((missing.ok, missing.filesChecked), (false, false));

      latestFolder.deleteSync(recursive: true);
      scope.writeAsStringSync('pruned\n');
      final promoted = await restarted.verify(full.name);
      expect((promoted.ok, promoted.filesChecked), (true, false));
    },
  );

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
        ..execute('CREATE TABLE files (id TEXT, size INTEGER)')
        ..execute("INSERT INTO files VALUES ('f1', 1)")
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
        ..execute('CREATE TABLE files (id TEXT, size INTEGER)')
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
    // The optional disk-space check uses df, which Windows may not have.
    if (!Platform.isWindows) {
      expect(await BackupJob.freeBytes(dir.path), greaterThan(0));
    }
  });

  test('backup times are read in family time, not server time', () {
    final dir = Directory.systemTemp.createTempSync('famio_backup_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory(p.join(dir.path, 'famio-20261006-030000')).createSync();
    final db = sqlite3.openInMemory();
    // UTC+14 all year, far from any server's own zone.
    final job = BackupJob(
      db: db,
      blobs: db,
      dir: dir.path,
      location: () => tz.getLocation('Pacific/Kiritimati'),
    );
    expect(job.list().single.at.toUtc(), DateTime.utc(2026, 10, 5, 13));
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
