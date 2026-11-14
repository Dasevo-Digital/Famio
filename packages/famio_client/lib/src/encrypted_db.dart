import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Opens the on-device database at [path], encrypted with [hexKey]
/// (SQLite3MultipleCiphers). A plain database from an older app version is
/// encrypted in place. `:memory:` or no key: unencrypted (tests).
///
/// [resetUnreadable]: a database this key does not open (encrypted on
/// another device, restored from its backup, #490) is started anew; the
/// server has what it held. Without it that is an error.
Database openDeviceDatabase(
  String path, {
  String? hexKey,
  bool resetUnreadable = false,
}) {
  if (path == ':memory:') return sqlite3.openInMemory();
  final file = File(path);
  final plain = file.existsSync() && _isPlain(file);
  final db = sqlite3.open(path);
  if (hexKey == null) return db;
  try {
    if (plain) {
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute("PRAGMA hexrekey = '$hexKey'");
    } else {
      db.execute("PRAGMA hexkey = '$hexKey'");
    }
    db.select('SELECT count(*) FROM sqlite_master');
    return db;
  } on SqliteException catch (e) {
    db.close();
    if (!resetUnreadable || plain || e.resultCode != 26) rethrow;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final part = File('$path$suffix');
      if (part.existsSync()) part.deleteSync();
    }
    return openDeviceDatabase(path, hexKey: hexKey);
  }
}

bool _isPlain(File file) {
  final raf = file.openSync();
  try {
    return String.fromCharCodes(raf.readSync(16)) == 'SQLite format 3\u0000';
  } finally {
    raf.closeSync();
  }
}
