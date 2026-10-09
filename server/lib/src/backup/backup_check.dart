import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../crypto/encrypted_db.dart';
import '../files/file_store.dart';

/// The result of trying a backup: can it be opened with the data key, is
/// it intact, and does it hold what the server holds?
class BackupCheck {
  const BackupCheck({
    required this.name,
    required this.at,
    required this.ok,
    this.problems = const [],
    this.notes = const [],
    this.users = 0,
    this.records = 0,
    this.files = 0,
    this.filesChecked = false,
  });

  factory BackupCheck.fromJson(Map<String, Object?> json) => BackupCheck(
    name: json['name'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime(2000),
    ok: json['ok'] as bool? ?? false,
    problems: [for (final x in json['problems'] as List? ?? const []) '$x'],
    notes: [for (final x in json['notes'] as List? ?? const []) '$x'],
    users: (json['users'] as num?)?.toInt() ?? 0,
    records: (json['records'] as num?)?.toInt() ?? 0,
    files: (json['files'] as num?)?.toInt() ?? 0,
    filesChecked: json['filesChecked'] as bool? ?? false,
  );

  final String name;
  final DateTime at;

  /// Restorable: opens with the key, intact, has members, no file lacks
  /// its contents.
  final bool ok;

  /// Why it is not [ok].
  final List<String> problems;

  /// Worth a look but no reason to distrust it, e.g. far fewer entries
  /// than the server has now.
  final List<String> notes;
  final int users;
  final int records;
  final int files;

  /// Whether files.db was there to check (only the newest backups keep it).
  final bool filesChecked;

  Map<String, Object?> toJson() => {
    'name': name,
    'at': at.toUtc().toIso8601String(),
    'ok': ok,
    'problems': problems,
    'notes': notes,
    'users': users,
    'records': records,
    'files': files,
    'filesChecked': filesChecked,
  };

  static const fileName = 'check.json';

  /// The stored result in backup [folder], or null.
  static BackupCheck? load(String folder) {
    final f = File(p.join(folder, fileName));
    if (!f.existsSync()) return null;
    try {
      return BackupCheck.fromJson(
        (jsonDecode(f.readAsStringSync()) as Map).cast(),
      );
    } on FormatException {
      return null;
    }
  }

  void save(String folder) => File(
    p.join(folder, fileName),
  ).writeAsStringSync(jsonEncode(toJson()), flush: true);
}

/// Checks the backup in [folder] without changing it: both databases are
/// opened read-only (an unencrypted file is never encrypted in place, no
/// journal files appear). [liveUsers] and [liveRecords] are the server's
/// numbers now, to spot a backup that holds far less. Runs in an isolate.
BackupCheck checkBackup(
  String folder, {
  required String? hexKey,
  required int liveUsers,
  required int liveRecords,
  DateTime? now,
}) {
  final name = p.basename(folder);
  final problems = <String>[];
  final notes = <String>[];
  var users = 0, records = 0, files = 0;
  var filesChecked = false;
  final fileIds = <String>{};

  Database? open(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final plain = isPlainSqlite(file);
    final db = sqlite3.open(
      Uri.file(path).replace(queryParameters: {'immutable': '1'}).toString(),
      mode: OpenMode.readOnly,
      uri: true,
    );
    try {
      if (!plain && hexKey != null) db.execute("PRAGMA hexkey = '$hexKey'");
      db.select('SELECT count(*) FROM sqlite_master');
      return db;
    } on SqliteException {
      db.close();
      rethrow;
    }
  }

  String integrity(Database db) =>
      db.select('PRAGMA quick_check').first.columnAt(0) as String;

  try {
    final main = open(p.join(folder, 'famio.db'));
    if (main == null) {
      problems.add('famio.db fehlt');
    } else {
      try {
        final check = integrity(main);
        if (check != 'ok') problems.add('famio.db beschädigt: $check');
        int count(String sql) => main.select(sql).first.columnAt(0) as int;
        users = count('SELECT count(*) FROM users');
        records = count('SELECT count(*) FROM records WHERE deleted = 0');
        files = count('SELECT count(*) FROM files');
        fileIds.addAll([
          for (final r in main.select('SELECT id FROM files'))
            r['id'] as String,
        ]);
      } finally {
        main.close();
      }
    }
  } on SqliteException catch (e) {
    problems.add(
      'famio.db lässt sich mit dem Datenschlüssel nicht öffnen (${e.message})',
    );
  }
  if (users == 0 && liveUsers > 0 && problems.isEmpty) {
    problems.add('Keine Mitglieder in der Sicherung');
  }

  try {
    final blobs = open(p.join(folder, 'files.db'));
    if (blobs != null) {
      filesChecked = true;
      try {
        final check = integrity(blobs);
        if (check != 'ok') problems.add('files.db beschädigt: $check');
        final stored = {
          for (final r in blobs.select(
            "SELECT DISTINCT id FROM blobs WHERE kind = '${FileStore.originalKind}'",
          ))
            r['id'] as String,
        };
        final missing = fileIds.difference(stored).length;
        if (missing > 0) {
          problems.add(
            missing == 1
                ? '1 Datei ohne Inhalt in files.db'
                : '$missing Dateien ohne Inhalt in files.db',
          );
        }
      } finally {
        blobs.close();
      }
    }
  } on SqliteException catch (e) {
    problems.add(
      'files.db lässt sich mit dem Datenschlüssel nicht öffnen (${e.message})',
    );
  }

  if (problems.isEmpty && liveRecords >= 50 && records < liveRecords ~/ 2) {
    notes.add(
      'Deutlich weniger Einträge als jetzt ($records statt $liveRecords) – '
      'seit der Sicherung kam viel dazu, oder es fehlt etwas.',
    );
  }
  return BackupCheck(
    name: name,
    at: now ?? DateTime.now(),
    ok: problems.isEmpty,
    problems: problems,
    notes: notes,
    users: users,
    records: records,
    files: files,
    filesChecked: filesChecked,
  );
}
