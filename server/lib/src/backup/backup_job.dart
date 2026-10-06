import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

/// One stored backup: a folder with `famio.db` and `files.db`.
class BackupInfo {
  const BackupInfo({required this.name, required this.at, required this.bytes});

  final String name;
  final DateTime at;
  final int bytes;

  Map<String, Object?> toJson() => {
    'name': name,
    'at': at.toUtc().toIso8601String(),
    'bytes': bytes,
  };
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
    this.hour = 3,
    this.daily = 7,
    this.weekly = 4,
    this.onError,
  });

  final Database db;
  final Database blobs;
  final String dir;
  final tz.Location Function() location;
  final int hour;
  final int daily;
  final int weekly;
  final void Function(String line)? onError;

  Timer? _timer;
  DateTime? lastAt;
  String? lastError;
  var _running = false;

  static final _name = RegExp(r'^famio-(\d{8})-(\d{6})$');

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
    final now = tz.TZDateTime.now(location());
    if (now.hour < hour) return;
    final today = '${now.year}${_two(now.month)}${_two(now.day)}';
    if (list().any((b) => b.name.startsWith('famio-$today'))) return;
    try {
      run();
    } catch (_) {
      // Recorded in lastError; tried again in half an hour.
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Writes a backup now and prunes old ones.
  BackupInfo run() {
    if (_running) throw StateError('Sicherung läuft bereits');
    _running = true;
    final now = tz.TZDateTime.now(location());
    final name =
        'famio-${now.year}${_two(now.month)}${_two(now.day)}-'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final target = Directory(p.join(dir, name));
    final partial = Directory(p.join(dir, '.$name.partial'));
    try {
      if (partial.existsSync()) partial.deleteSync(recursive: true);
      partial.createSync(recursive: true);
      String quoted(String path) => "'${path.replaceAll("'", "''")}'";
      db.execute('VACUUM INTO ${quoted(p.join(partial.path, 'famio.db'))}');
      blobs.execute('VACUUM INTO ${quoted(p.join(partial.path, 'files.db'))}');
      // Only complete backups get their final name.
      partial.renameSync(target.path);
      lastAt = DateTime.now();
      lastError = null;
      prune();
      return list().firstWhere((b) => b.name == name);
    } catch (e) {
      lastError = '$e';
      onError?.call('[backup] Sicherung fehlgeschlagen: $e');
      if (partial.existsSync()) partial.deleteSync(recursive: true);
      rethrow;
    } finally {
      _running = false;
    }
  }

  /// Stored backups, newest first.
  List<BackupInfo> list() {
    final root = Directory(dir);
    if (!root.existsSync()) return const [];
    final found = <BackupInfo>[];
    for (final entry in root.listSync().whereType<Directory>()) {
      final name = p.basename(entry.path);
      final m = _name.firstMatch(name);
      if (m == null) continue;
      final d = m[1]!;
      final t = m[2]!;
      final at = DateTime(
        int.parse(d.substring(0, 4)),
        int.parse(d.substring(4, 6)),
        int.parse(d.substring(6, 8)),
        int.parse(t.substring(0, 2)),
        int.parse(t.substring(2, 4)),
        int.parse(t.substring(4, 6)),
      );
      final bytes = entry.listSync().whereType<File>().fold<int>(
        0,
        (sum, f) => sum + f.lengthSync(),
      );
      found.add(BackupInfo(name: name, at: at, bytes: bytes));
    }
    return found..sort((a, b) => b.at.compareTo(a.at));
  }

  /// Keeps the newest per day for [daily] days and the newest per week
  /// for [weekly] weeks.
  void prune() {
    final keep = <String>{};
    final days = <String>{};
    final weeks = <String>{};
    var dailyKept = 0;
    var weeklyKept = 0;
    for (final b in list()) {
      final day = '${b.at.year}-${b.at.month}-${b.at.day}';
      final monday = DateTime(
        b.at.year,
        b.at.month,
        b.at.day - b.at.weekday + 1,
      );
      final week = '${monday.year}-${monday.month}-${monday.day}';
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
    for (final b in list()) {
      if (!keep.contains(b.name)) {
        Directory(p.join(dir, b.name)).deleteSync(recursive: true);
      }
    }
  }

  /// The directory of backup [name], or null.
  Directory? folder(String name) {
    if (_name.firstMatch(name) == null) return null;
    final d = Directory(p.join(dir, name));
    return d.existsSync() ? d : null;
  }

  Map<String, Object?> status() => {
    'dir': dir,
    'lastAt': (lastAt ?? list().firstOrNull?.at)?.toUtc().toIso8601String(),
    'lastError': lastError,
    'backups': [for (final b in list()) b.toJson()],
  };
}
