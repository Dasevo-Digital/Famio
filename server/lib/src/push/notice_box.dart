import 'dart:async';

import 'package:sqlite3/sqlite3.dart';

import 'push_service.dart';

/// Notifications for Famio's own push (no ntfy needed): kept a few days
/// per member; devices fetch them with a request the server holds open
/// until something new arrives (long polling). The Android app does so
/// from a background service, the desktop apps while they run.
class NoticeBox {
  NoticeBox(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS notices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        member_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        at INTEGER NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        brief TEXT NOT NULL,
        tag TEXT NOT NULL
      )''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS notices_member ON notices(member_id, id)',
    );
    final columns = {
      for (final c in _db.select('PRAGMA table_info(notices)')) c['name'],
    };
    if (!columns.contains('quiet')) {
      _db.execute(
        'ALTER TABLE notices ADD COLUMN quiet INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  final Database _db;

  /// How long a notification waits for devices that were offline.
  static const keep = Duration(days: 3);
  static const _maxPerMember = 200;

  /// Open requests per member; more are answered right away.
  static const _maxWaiting = 10;

  final _waiting = <String, Set<Completer<void>>>{};

  /// Stores [notice] for [memberIds] and wakes their waiting devices.
  /// Devices show it without sound for those in [quiet].
  void add(
    Iterable<String> memberIds,
    PushNotice notice, [
    Set<String> quiet = const {},
  ]) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in memberIds.toSet()) {
      // Records may name members that no longer exist (deleted, imported).
      _db.execute(
        'INSERT INTO notices (member_id, at, title, body, brief, tag, quiet)'
        ' SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE EXISTS'
        ' (SELECT 1 FROM users WHERE id = ?1)',
        [
          id,
          now,
          notice.title,
          notice.body,
          notice.brief,
          notice.tag,
          if (quiet.contains(id)) 1 else 0,
        ],
      );
      if (_db.updatedRows == 0) continue;
      _db.execute(
        'DELETE FROM notices WHERE member_id = ?1 AND id <= ('
        'SELECT id FROM notices WHERE member_id = ?1'
        ' ORDER BY id DESC LIMIT 1 OFFSET $_maxPerMember)',
        [id],
      );
      for (final waiter in _waiting.remove(id) ?? const <Completer<void>>{}) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  /// Newest id of [memberId] (0 without any): where a new device starts.
  int latest(String memberId) =>
      _db
              .select(
                'SELECT COALESCE(MAX(id), 0) FROM notices WHERE member_id = ?',
                [memberId],
              )
              .first
              .columnAt(0)
          as int;

  List<Map<String, Object?>> after(String memberId, int after) => [
    for (final row in _db.select(
      'SELECT * FROM notices WHERE member_id = ? AND id > ?'
      ' ORDER BY id LIMIT 50',
      [memberId, after],
    ))
      {
        'id': row['id'],
        'at': DateTime.fromMillisecondsSinceEpoch(
          row['at'] as int,
          isUtc: true,
        ).toIso8601String(),
        'title': row['title'],
        'body': row['body'],
        'brief': row['brief'],
        'tag': row['tag'],
        'quiet': row['quiet'] == 1,
      },
  ];

  /// Notifications after [after], waiting up to [timeout] for the first.
  Future<List<Map<String, Object?>>> wait(
    String memberId,
    int after, {
    required Duration timeout,
  }) async {
    final ready = this.after(memberId, after);
    final waiters = _waiting.putIfAbsent(memberId, () => {});
    if (ready.isNotEmpty ||
        timeout <= Duration.zero ||
        waiters.length >= _maxWaiting) {
      if (waiters.isEmpty) _waiting.remove(memberId);
      return ready;
    }
    final waiter = Completer<void>();
    waiters.add(waiter);
    try {
      await waiter.future.timeout(timeout, onTimeout: () {});
    } finally {
      _waiting[memberId]?.remove(waiter);
      if (_waiting[memberId]?.isEmpty ?? false) _waiting.remove(memberId);
    }
    return this.after(memberId, after);
  }

  /// Requests currently held open (all members).
  int get waiting => _waiting.values.fold(0, (n, w) => n + w.length);

  void collectGarbage() => _db.execute('DELETE FROM notices WHERE at < ?', [
    DateTime.now().subtract(keep).millisecondsSinceEpoch,
  ]);

  /// "Alle Daten löschen": the texts go too.
  void deleteAll() => _db.execute('DELETE FROM notices');

  /// Wakes all waiting requests, e.g. when the server stops.
  void close() {
    for (final waiters in _waiting.values) {
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
    _waiting.clear();
  }
}
