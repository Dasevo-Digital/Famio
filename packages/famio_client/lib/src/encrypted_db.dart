import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'unreadable.dart';

/// Opens the on-device database at [path], encrypted with [hexKey]
/// (SQLite3MultipleCiphers). A plain database from an older app version is
/// encrypted in place. `:memory:` or no key: unencrypted (tests).
///
/// [unreadable]: what happens when this key does not open the database, see
/// [UnreadableDatabase].
Database openDeviceDatabase(
  String path, {
  String? hexKey,
  UnreadableDatabase unreadable = UnreadableDatabase.fail,
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
    // 26: not a database for this key; 11: damaged.
    final unopened = e.resultCode == 26 || e.resultCode == 11;
    if (plain || !unopened) rethrow;
    switch (unreadable) {
      case UnreadableDatabase.fail:
        rethrow;
      case UnreadableDatabase.reset when e.resultCode == 26:
        for (final suffix in _parts) {
          final part = File('$path$suffix');
          if (part.existsSync()) part.deleteSync();
        }
      case UnreadableDatabase.reset || UnreadableDatabase.setAside:
        // One copy set aside per database: an older one goes.
        final aside = '$path.unreadable';
        for (final suffix in _parts) {
          final old = File('$aside$suffix');
          if (old.existsSync()) old.deleteSync();
          final part = File('$path$suffix');
          if (part.existsSync()) part.renameSync('$aside$suffix');
        }
        // From now, for how long the app keeps it (#561).
        final copy = File(aside);
        if (copy.existsSync()) copy.setLastModifiedSync(DateTime.now());
        noteSetAside(aside);
    }
    return openDeviceDatabase(path, hexKey: hexKey);
  }
}

const _parts = ['', '-wal', '-shm', '-journal'];

bool _isPlain(File file) {
  final raf = file.openSync();
  try {
    return String.fromCharCodes(raf.readSync(16)) == 'SQLite format 3\u0000';
  } finally {
    raf.closeSync();
  }
}
