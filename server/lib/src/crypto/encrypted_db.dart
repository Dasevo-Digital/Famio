import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

/// Thrown when an encrypted database cannot be opened with the given key.
class DataKeyException implements Exception {
  const DataKeyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens the SQLite database at [path], encrypted with [hexKey]
/// (SQLite3MultipleCiphers, ChaCha20-Poly1305). A plain database from an
/// older version is encrypted in place. Without a key, or for `:memory:`,
/// the database stays unencrypted (tests).
Database openEncrypted(String path, {String? hexKey}) {
  if (path == ':memory:') return sqlite3.openInMemory();
  final file = File(path);
  final plainExisting = file.existsSync() && isPlainSqlite(file);
  final db = sqlite3.open(path);
  if (hexKey == null) return db;
  try {
    if (plainExisting) {
      // Rekeying needs a rollback journal; WAL is switched on again later.
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute("PRAGMA hexrekey = '$hexKey'");
    } else {
      db.execute("PRAGMA hexkey = '$hexKey'");
    }
    // Fails with "file is not a database" for a wrong key.
    db.select('SELECT count(*) FROM sqlite_master');
  } on SqliteException {
    db.close();
    throw DataKeyException(
      'Die Datenbank $path lässt sich mit dem vorhandenen Schlüssel nicht '
      'öffnen. Stimmt FAMIO_KEY_FILE?',
    );
  }
  return db;
}

/// Whether [file] is an unencrypted SQLite database.
bool isPlainSqlite(File file) {
  final raf = file.openSync();
  try {
    final header = raf.readSync(16);
    return String.fromCharCodes(header) == 'SQLite format 3\u0000';
  } finally {
    raf.closeSync();
  }
}

/// Loads the data key from [path], creating a new random one if there is no
/// key yet. Refuses to create one when [dataDir] already holds encrypted
/// data: a lost key must not silently lead to a fresh, empty server.
String loadOrCreateDataKey(String path, {required String dataDir}) {
  final file = File(path);
  if (file.existsSync()) {
    _ensureOwnerOnly(file);
    final key = file.readAsStringSync().trim();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      throw DataKeyException('Schlüsseldatei $path ist ungültig.');
    }
    return key;
  }
  for (final name in ['famio.db', 'files.db']) {
    final existing = File('$dataDir/$name');
    if (existing.existsSync() &&
        existing.lengthSync() > 0 &&
        !isPlainSqlite(existing)) {
      throw DataKeyException(
        'Schlüsseldatei $path fehlt, die Daten in $dataDir sind aber '
        'verschlüsselt. Bitte die gesicherte Schlüsseldatei zurücklegen.',
      );
    }
  }
  final random = Random.secure();
  final key = List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$key\n', flush: true);
  _ensureOwnerOnly(file);
  return key;
}

/// The key is as sensitive as the encrypted databases. Dart has no chmod API,
/// so server platforms use the small POSIX utility and verify the result.
void _ensureOwnerOnly(File file) {
  if (Platform.isWindows) return;
  final result = Process.runSync('chmod', ['600', file.path]);
  if (result.exitCode != 0 ||
      (FileStat.statSync(file.path).mode & 0x1ff) != 0x180) {
    throw DataKeyException(
      'Schlüsseldatei ${file.path} muss die Rechte 0600 haben.',
    );
  }
}
