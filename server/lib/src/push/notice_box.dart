import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
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
    for (final column in ['quiet', 'alarm']) {
      if (!columns.contains(column)) {
        _db.execute(
          'ALTER TABLE notices ADD COLUMN $column INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    // What tapping it opens (#385).
    if (!columns.contains('target')) {
      _db.execute('ALTER TABLE notices ADD COLUMN target TEXT');
    }
    // The random key of its link in ntfy (#578, see NoticeLink).
    if (!columns.contains('link')) {
      _db.execute('ALTER TABLE notices ADD COLUMN link TEXT');
    }
    _db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS notices_link ON notices(link)',
    );
  }

  final Database _db;

  /// How long a notification waits for devices that were offline.
  static const keep = Duration(days: 3);
  static const _maxPerMember = 200;

  /// Open requests per member; more are answered right away.
  static const _maxWaiting = 10;

  final _waiting = <String, Set<Completer<void>>>{};

  /// The link keys [add] gave each notice, per member ([linkFor]).
  final _links = Expando<Map<String, String>>();

  static final _random = Random.secure();

  /// Stores [notice] for [memberIds] and wakes their waiting devices.
  /// Devices show it without sound for those in [quiet].
  void add(
    Iterable<String> memberIds,
    PushNotice notice, [
    Set<String> quiet = const {},
  ]) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final links = <String, String>{};
    for (final id in memberIds.toSet()) {
      final link = notice.target == null ? null : _newLink();
      // Records may name members that no longer exist (deleted, imported).
      _db.execute(
        'INSERT INTO notices (member_id, at, title, body, brief, tag, quiet,'
        ' alarm, target, link) SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10'
        ' WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)',
        [
          id,
          now,
          notice.title,
          notice.body,
          notice.brief,
          notice.tag,
          if (quiet.contains(id)) 1 else 0,
          if (notice.urgent) 1 else 0,
          notice.target?.encode(),
          link,
        ],
      );
      if (_db.updatedRows == 0) continue;
      if (link != null) links[id] = link;
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
    if (links.isNotEmpty) _links[notice] = links;
  }

  /// The key of [notice]'s link for [memberId], as [add] stored it; null
  /// without a target or when it was not stored for this member. Others
  /// learn nothing from it: see [targetOf].
  String? linkFor(String memberId, PushNotice notice) =>
      _links[notice]?[memberId];

  /// What the notice with link [key] opens, for its own member only; null
  /// for an unknown key, a notice of someone else or one already removed.
  NoticeTarget? targetOf(String memberId, String key) => NoticeTarget.decode(
    _db.select('SELECT target FROM notices WHERE link = ? AND member_id = ?', [
          key,
          memberId,
        ]).firstOrNull?['target']
        as String?,
  );

  /// 128 random bits: nobody guesses the link of someone else's notice.
  static String _newLink() => base64Url
      .encode(List.generate(16, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

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
        'alarm': row['alarm'] == 1,
        if (row['target'] case final String target) 'target': target,
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
