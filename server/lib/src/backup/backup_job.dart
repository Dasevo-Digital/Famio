import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import '../crypto/encrypted_db.dart';
import 'backup_check.dart';
import '../i18n.dart';

/// One stored backup: a folder with `famio.db` and `files.db`.
class BackupInfo {
  const BackupInfo({
    required this.name,
    required this.at,
    required this.bytes,
    this.check,
  });

  final String name;
  final DateTime at;
  final int bytes;

  /// The last test of this backup, if any.
  final BackupCheck? check;

  Map<String, Object?> toJson() => {
    'name': name,
    'at': at.toUtc().toIso8601String(),
    'bytes': bytes,
    'check': ?check?.toJson(),
  };
}

class _FailedBackupCheck implements Exception {
  const _FailedBackupCheck(this.problems);
  final List<String> problems;

  @override
  String toString() => problems.join('; ');
}

/// Backups while the server runs: SQLite's `VACUUM INTO` writes a
/// consistent copy of both databases, encrypted with the same data key
/// (restoring needs the key file too). Nightly at [hour] (family time),
/// keeping the last [daily] days and one per week for [weekly] weeks.
class BackupJob {
  BackupJob({
    required this.db,
    required this.blobs,
    required this.dir,
    required this.location,
    DateTime Function()? clock,
    this.dbPath,
    this.blobsPath,
    this.hexKey,
    this.hour = 3,
    this.daily = 7,
    this.weekly = 4,
    this.filesKeep = 2,
    this.onError,
  }) : _clock = clock ?? DateTime.now;

  final Database db;
  final Database blobs;

  /// The database files: with them the copy runs in a separate isolate on
  /// its own connection, so the server keeps answering (a large files.db
  /// takes minutes). Without (in-memory tests) it runs here.
  final String? dbPath;
  final String? blobsPath;
  final String? hexKey;

  /// Only this many newest backups keep files.db: it holds every document
  /// and photo (up to the storage limit) and would otherwise be copied a
  /// dozen times. Older backups have famio.db only.
  final int filesKeep;
  final String dir;
  final tz.Location Function() location;
  final DateTime Function() _clock;
  final int hour;
  final int daily;
  final int weekly;
  final void Function(String line)? onError;

  Timer? _timer;
  DateTime? lastAt;
  String? lastError;
  var _running = false;

  /// The latest test of a backup (see [verify]).
  BackupCheck? lastCheck;

  static const _createdAtFile = 'created-at';
  static final _name = RegExp(r'^famio-(\d{8})-(\d{6})(?:-(\d{6}))?$');

  /// A nightly backup is missing when the newest is older than this: one
  /// night plus the retries of the following day.
  static const freshFor = Duration(hours: 36);

  void start() {
    _timer ??= Timer.periodic(const Duration(minutes: 30), (_) => _maybe());
    _maybe();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Once a day after [hour], if today has none yet.
  void _maybe() {
    final now = tz.TZDateTime.from(_clock(), location());
    if (now.hour < hour) return;
    final today = '${now.year}${_two(now.month)}${_two(now.day)}';
    if (list().any(
      (b) => b.name.startsWith('famio-$today') && b.check?.ok != false,
    )) {
      return;
    }
    // Errors are recorded in lastError; tried again in half an hour.
    unawaited(run().then((_) {}, onError: (Object _) {}));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Writes a backup now and prunes old ones.
  Future<BackupInfo> run() async {
    if (_running) throw StateError(t('Sicherung läuft bereits'));
    _running = true;
    Directory? partial;
    try {
      final now = tz.TZDateTime.from(_clock(), location());
      final stamp =
          'famio-${now.year}${_two(now.month)}${_two(now.day)}-'
          '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final root = Directory(dir)..createSync(recursive: true);
      await _checkSpace();
      partial = root.createTempSync('.$stamp.partial-');
      await _copy(db, dbPath, p.join(partial.path, 'famio.db'));
      await _copy(blobs, blobsPath, p.join(partial.path, 'files.db'));
      final createdAt = now.toUtc();
      File(p.join(partial.path, _createdAtFile)).writeAsStringSync(
        '${createdAt.toIso8601String()}\n${now.timeZoneOffset.inSeconds}',
        flush: true,
      );
      final check = await _inspect(
        partial.path,
        name: stamp,
        requireFiles: true,
      );
      if (!check.ok) {
        lastCheck = check;
        throw _FailedBackupCheck(check.problems);
      }
      final name = _publish(partial, root, stamp, check);
      partial = null;
      prune(protectedName: name);
      final backup = list().firstWhere((b) => b.name == name);
      lastAt = createdAt;
      lastError = null;
      lastCheck = backup.check;
      return backup;
    } catch (e) {
      lastError = '$e';
      onError?.call('[backup] Sicherung fehlgeschlagen: $e');
      if (partial != null && partial.existsSync()) {
        partial.deleteSync(recursive: true);
      }
      rethrow;
    } finally {
      _running = false;
    }
  }

  /// Only complete backups get a final name. The first keeps the old
  /// format. Further backups in the same second sort after it.
  static String _publish(
    Directory partial,
    Directory root,
    String stamp,
    BackupCheck check,
  ) {
    while (true) {
      var next = 0;
      // Pruning can already have removed the name without a suffix. Find
      // the highest retained sequence so a later backup still sorts last.
      for (final entry in root.listSync(followLinks: false)) {
        final name = p.basename(entry.path);
        if (!name.startsWith(stamp)) continue;
        final match = _name.firstMatch(name);
        if (match == null) continue;
        final sequence = int.parse(match[3] ?? '0');
        if (sequence >= next) next = sequence + 1;
      }
      if (next > 999999) {
        throw FileSystemException('Backup sequence exhausted', root.path);
      }
      final name = next == 0
          ? stamp
          : '$stamp-${next.toString().padLeft(6, '0')}';
      final target = p.join(root.path, name);
      check.save(partial.path, publishedName: name);
      try {
        partial.renameSync(target);
        return name;
      } on FileSystemException {
        // The name may have appeared between listing and renaming. Keep
        // the completed temporary copy and allocate another name.
        if (FileSystemEntity.typeSync(target, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
  }

  /// Tries backup [name] without changing it (read-only, in an isolate):
  /// opens both databases with the data key, checks their integrity, that
  /// there are members and every file has its contents, and compares with
  /// the server now. The result is kept in the backup's folder.
  Future<BackupCheck> verify(String name) async {
    final d = folder(name);
    if (d == null) throw ArgumentError.value(name, 'name', 'unbekannt');
    final check = await _inspect(d.path, name: name);
    check.save(d.path);
    lastCheck = check;
    if (!check.ok) {
      onError?.call(
        '[backup] Prüfung von $name fehlgeschlagen: '
        '${check.problems.join('; ')}',
      );
    }
    return check;
  }

  Future<BackupCheck> _inspect(
    String path, {
    required String name,
    bool requireFiles = false,
  }) {
    int count(String sql) => db.select(sql).first.columnAt(0) as int;
    return _checkIn(
      path,
      name,
      hexKey,
      count('SELECT count(*) FROM users'),
      count('SELECT count(*) FROM records WHERE deleted = 0'),
      requireFiles,
    );
  }

  /// [checkBackup] in an isolate; static so the closure carries nothing
  /// but these values (a database connection cannot be sent).
  static Future<BackupCheck> _checkIn(
    String path,
    String name,
    String? key,
    int liveUsers,
    int liveRecords,
    bool requireFiles,
  ) => Isolate.run(
    () => checkBackup(
      path,
      name: name,
      hexKey: key,
      liveUsers: liveUsers,
      liveRecords: liveRecords,
      requireFiles: requireFiles,
    ),
  );

  static String _quoted(String path) => "'${path.replaceAll("'", "''")}'";

  /// `VACUUM INTO` [target]: in a separate isolate when the database is a
  /// file, so the server is not blocked.
  Future<void> _copy(Database open, String? path, String target) async {
    if (path == null || !File(path).existsSync()) {
      open.execute('VACUUM INTO ${_quoted(target)}');
      return;
    }
    final key = hexKey;
    await Isolate.run(() {
      final own = openEncrypted(path, hexKey: key);
      try {
        own.execute('VACUUM INTO ${_quoted(target)}');
      } finally {
        own.close();
      }
    });
  }

  /// Refuses to start when the disk would run (nearly) full: the copy
  /// needs about the size of both databases.
  Future<void> _checkSpace() async {
    var needed = 64 * 1024 * 1024;
    for (final path in [dbPath, blobsPath]) {
      if (path == null) continue;
      for (final f in [path, '$path-wal']) {
        final file = File(f);
        if (file.existsSync()) needed += file.lengthSync();
      }
    }
    final free = await freeBytes(dir);
    if (free != null && free < needed) {
      throw StateError(
        t(
          'Zu wenig Speicherplatz für die Sicherung: frei {free} MB, nötig etwa {needed} MB',
          {'free': free ~/ (1024 * 1024), 'needed': needed ~/ (1024 * 1024)},
        ),
      );
    }
  }

  /// Free bytes on the disk of [path] (via `df`), or null if unknown.
  static Future<int?> freeBytes(String path) async {
    try {
      final r = await Process.run('df', ['-Pk', path]);
      if (r.exitCode != 0) return null;
      final lines = (r.stdout as String).trim().split('\n');
      final cols = lines.last.trim().split(RegExp(r'\s+'));
      final kb = int.tryParse(cols.length > 3 ? cols[3] : '');
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _recordedAt(
    Directory folder,
    DateTime wall,
    tz.Location zone,
  ) {
    try {
      final lines = File(
        p.join(folder.path, _createdAtFile),
      ).readAsStringSync().split('\n');
      final at = DateTime.tryParse(lines.first);
      if (at == null || !at.isUtc || at.toIso8601String() != lines.first) {
        return null;
      }
      // Older UTC-only metadata can be verified against the current zone.
      // New backups keep their original offset even after a zone change.
      final seconds = switch (lines.length) {
        1 => zone.timeZone(at.millisecondsSinceEpoch).offset.inSeconds,
        2 => int.tryParse(lines[1]),
        _ => null,
      };
      if (seconds == null || seconds.abs() >= Duration.secondsPerDay) {
        return null;
      }
      final local = at.add(Duration(seconds: seconds));
      return !local.isBefore(wall) &&
              local.isBefore(wall.add(const Duration(seconds: 1)))
          ? at
          : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static DateTime _legacyAt(DateTime wall, tz.Location zone) {
    final resolved = tz.TZDateTime(
      zone,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
    );
    // A legacy name cannot tell the two occurrences of a repeated hour
    // apart. Prefer the earlier instant so an older copy cannot displace
    // a new backup with a recorded timestamp during the changeover.
    final previousOffset = zone
        .timeZone(wall.subtract(const Duration(days: 1)).millisecondsSinceEpoch)
        .offset;
    final earlier = tz.TZDateTime.from(wall.subtract(previousOffset), zone);
    return earlier.isBefore(resolved) &&
            earlier.timeZoneOffset == previousOffset
        ? earlier.toUtc()
        : resolved.toUtc();
  }

  /// Stored backups, newest first.
  List<BackupInfo> list() {
    final root = Directory(dir);
    if (!root.existsSync()) return const [];
    final zone = location();
    final found = <BackupInfo>[];
    for (final entry in root.listSync().whereType<Directory>()) {
      final name = p.basename(entry.path);
      final m = _name.firstMatch(name);
      if (m == null) continue;
      final wall = DateTime.parse('${m[1]}T${m[2]}Z');
      final at = _recordedAt(entry, wall, zone) ?? _legacyAt(wall, zone);
      final bytes = entry.listSync().whereType<File>().fold<int>(
        0,
        (sum, f) => sum + f.lengthSync(),
      );
      found.add(
        BackupInfo(
          name: name,
          at: at,
          bytes: bytes,
          check: BackupCheck.load(entry.path),
        ),
      );
    }
    return found..sort((a, b) {
      final byTime = b.at.compareTo(a.at);
      return byTime == 0 ? b.name.compareTo(a.name) : byTime;
    });
  }

  /// Keeps the newest per day for [daily] days and the newest per week
  /// for [weekly] weeks.
  void prune({String? protectedName}) {
    final keep = <String>{};
    final days = <String>{};
    final weeks = <String>{};
    var dailyKept = 0;
    var weeklyKept = 0;
    final backups = list();
    for (final b in backups) {
      if (b.check?.ok == false) continue;
      // The name retains the family day in effect when the copy was made.
      final day = b.name.substring(6, 14);
      final date = DateTime.parse('${day}T00:00:00Z');
      final monday = date.subtract(Duration(days: date.weekday - 1));
      final week = monday.toIso8601String();
      // An older backup of a day already kept.
      if (!days.add(day)) continue;
      if (dailyKept < daily) {
        dailyKept++;
        weeks.add(week);
        keep.add(b.name);
      } else if (weeklyKept < weekly && weeks.add(week)) {
        weeklyKept++;
        keep.add(b.name);
      }
    }
    // A corrected clock or old metadata may still put the successful
    // copy behind an existing one. Give it a chance to be restored too.
    if (protectedName != null) keep.add(protectedName);
    for (final b in backups) {
      if (!keep.contains(b.name)) {
        Directory(p.join(dir, b.name)).deleteSync(recursive: true);
      }
    }
    // Documents and photos only in the newest few.
    for (final b
        in backups.where((b) => keep.contains(b.name)).skip(filesKeep)) {
      if (b.name == protectedName) continue;
      final files = File(p.join(dir, b.name, 'files.db'));
      if (files.existsSync()) files.deleteSync();
    }
  }

  /// The directory of backup [name], or null.
  Directory? folder(String name) {
    if (_name.firstMatch(name) == null) return null;
    final d = Directory(p.join(dir, name));
    return d.existsSync() ? d : null;
  }

  Map<String, Object?> status() {
    final backups = list();
    final check =
        lastCheck ??
        [
          for (final b in backups)
            if (b.check != null) b.check!,
        ].fold<BackupCheck?>(
          null,
          (a, c) => a == null || c.at.isAfter(a.at) ? c : a,
        );
    return {
      'dir': dir,
      'lastAt': (lastAt ?? backups.firstOrNull?.at)?.toUtc().toIso8601String(),
      'lastError': lastError,
      'lastCheck': check?.toJson(),
      'backups': [for (final b in backups) b.toJson()],
    };
  }
}
