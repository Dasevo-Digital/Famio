import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Changes a session left unsent when it ended elsewhere (a new password on
/// another device, "Überall abmelden"), #337. The database of this account
/// stays on the device where it was, encrypted as before, with only these
/// changes in it (#560): signing in again with the same account at the same
/// server opens it, downloads everything anew and sends what waits. Another
/// account or server, a discard or [keptFor] delete it. Of a removed
/// account nothing is kept.
class WaitingChanges {
  const WaitingChanges({
    required this.server,
    required this.memberId,
    required this.username,
    required this.count,
    required this.since,
  });

  /// The server address as the session had it (normalized).
  final String server;
  final String memberId;

  /// To fill in the sign-in form.
  final String username;

  /// How many records were not on the server yet.
  final int count;

  /// When the session ended.
  final DateTime since;

  /// After that they go at the next start.
  static const keptFor = Duration(days: 14);

  static const _key = 'waitingChanges';

  bool belongsTo(String server, String memberId) =>
      this.server == server && this.memberId == memberId;

  bool expired(DateTime now) => now.difference(since) >= keptFor;

  /// The account's database in [dir] (the app's support folder).
  String database(String dir) => p.join(dir, databaseName(memberId));

  static String databaseName(String memberId) => 'famio_$memberId.db';

  static WaitingChanges? read(SharedPreferences prefs) {
    final saved = prefs.getString(_key);
    if (saved == null) return null;
    try {
      final json = (jsonDecode(saved) as Map).cast<String, Object?>();
      return WaitingChanges(
        server: json['server'] as String,
        memberId: json['member'] as String,
        username: json['username'] as String? ?? '',
        count: json['count'] as int,
        since: DateTime.fromMillisecondsSinceEpoch(json['since'] as int),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> save(SharedPreferences prefs) => prefs.setString(
    _key,
    jsonEncode({
      'server': server,
      'member': memberId,
      'username': username,
      'count': count,
      'since': since.millisecondsSinceEpoch,
    }),
  );

  static Future<void> forget(SharedPreferences prefs) => prefs.remove(_key);
}

/// Deletes the on-device database [name] in [dir] with its journal files.
void deleteDeviceDatabase(String dir, String name) {
  for (final suffix in const ['', '-journal', '-wal', '-shm']) {
    final file = File(p.join(dir, '$name$suffix'));
    if (file.existsSync()) file.deleteSync();
  }
}

/// How long a database set aside because it did not open (#490) is kept:
/// nothing in Famio reads it, it only holds what the device had not sent
/// yet, so it goes after that, when its account signs out or another one
/// signs in (#561).
const setAsideKeptFor = Duration(days: 30);

/// Deletes the copy set aside of the database [name] in [dir].
void deleteSetAside(String dir, String name) =>
    deleteDeviceDatabase(dir, '$name.unreadable');

/// Deletes the copies set aside in [dir] older than [setAsideKeptFor] and,
/// given [memberId], those of other accounts.
void pruneSetAside(String dir, {required DateTime now, String? memberId}) {
  final folder = Directory(dir);
  if (!folder.existsSync()) return;
  for (final entry in folder.listSync()) {
    final name = p.basename(entry.path);
    if (entry is! File || !name.endsWith('.db.unreadable')) continue;
    final database = name.substring(0, name.length - '.unreadable'.length);
    final other = memberId != null && !database.endsWith('_$memberId.db');
    if (other || now.difference(entry.lastModifiedSync()) >= setAsideKeptFor) {
      deleteSetAside(dir, database);
    }
  }
}
