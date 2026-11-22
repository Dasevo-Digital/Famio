@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// tool/famio-restore-backup.sh on backup folders as the server writes them
/// (#360, #572): what a failed check means, file modes, set-aside folders.
void main() {
  final script = p.normalize(
    p.join(Directory.current.path, '..', 'tool', 'famio-restore-backup.sh'),
  );
  late Directory root;
  late Directory data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('famio_restore_');
    data = Directory(p.join(root.path, 'data'))..createSync();
    File(p.join(data.path, 'famio.db')).writeAsStringSync('today');
    File(p.join(data.path, 'files.db')).writeAsStringSync('today files');
  });
  tearDown(() => root.deleteSync(recursive: true));

  String backup({bool withFiles = true, Map<String, Object?>? check}) {
    final dir = Directory(p.join(root.path, 'famio-20261120-030000'))
      ..createSync();
    File(p.join(dir.path, 'famio.db')).writeAsStringSync('backup');
    if (withFiles) {
      File(p.join(dir.path, 'files.db')).writeAsStringSync('backup files');
    }
    if (check != null) {
      File(p.join(dir.path, 'check.json')).writeAsStringSync(jsonEncode(check));
    }
    return dir.path;
  }

  Future<ProcessResult> restore(List<String> args) =>
      Process.run('sh', [script, ...args]);

  String read(String name) => File(p.join(data.path, name)).readAsStringSync();
  List<Directory> aside() =>
      data
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('before-restore-'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test(
    'restores both databases for the owner only, the old ones aside',
    () async {
      final r = await restore([
        backup(check: {'ok': true, 'problems': []}),
        data.path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect((read('famio.db'), read('files.db')), ('backup', 'backup files'));
      for (final name in ['famio.db', 'files.db']) {
        expect(
          File(p.join(data.path, name)).statSync().modeString(),
          'rw-------',
        );
      }
      final kept = aside().single;
      expect(File(p.join(kept.path, 'famio.db')).readAsStringSync(), 'today');
      expect(kept.statSync().modeString(), 'rwx------');
    },
  );

  test('a backup without files.db leaves today\'s files', () async {
    final r = await restore([backup(withFiles: false), data.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect((read('famio.db'), read('files.db')), ('backup', 'today files'));
    expect(r.stdout, contains('keine Dateien'));
  });

  test('a backup whose check failed needs --force', () async {
    final folder = backup(
      check: {
        'ok': false,
        'problems': ['1 Datei ohne Inhalt in files.db'],
      },
    );
    final refused = await restore([folder, data.path]);
    expect(refused.exitCode, 65);
    expect(refused.stderr, contains('ACHTUNG'));
    expect(refused.stderr, contains('1 Datei ohne Inhalt in files.db'));
    // Nothing changed.
    expect((read('famio.db'), read('files.db')), ('today', 'today files'));
    expect(aside(), isEmpty);

    final forced = await restore(['--force', folder, data.path]);
    expect(forced.exitCode, 0, reason: '${forced.stdout}${forced.stderr}');
    expect(forced.stderr, contains('ACHTUNG'));
    expect(read('famio.db'), 'backup');
  });

  test('only the three newest set-aside folders stay', () async {
    for (final old in [
      'before-restore-20261101-010101',
      'before-restore-20261102-010101',
      'before-restore-20261103-010101',
      'before-restore-20261104-010101',
    ]) {
      Directory(p.join(data.path, old)).createSync();
    }
    final r = await restore([backup(), data.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final names = [for (final d in aside()) p.basename(d.path)];
    expect(names, hasLength(3));
    expect(names.take(2), [
      'before-restore-20261103-010101',
      'before-restore-20261104-010101',
    ]);
    expect(
      File(p.join(aside().last.path, 'famio.db')).readAsStringSync(),
      'today',
    );
  });
}
