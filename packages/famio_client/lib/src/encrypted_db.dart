import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Opens the on-device database at [path], encrypted with [hexKey]
/// (SQLite3MultipleCiphers). A plain database from an older app version is
/// encrypted in place. `:memory:` or no key: unencrypted (tests).
Database openDeviceDatabase(String path, {String? hexKey}) {
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
  } on SqliteException {
    db.close();
    rethrow;
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
